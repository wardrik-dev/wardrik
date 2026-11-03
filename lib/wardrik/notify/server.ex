defmodule Wardrik.Notify.Server do
  @moduledoc false

  use DurableServer, vsn: 1

  require Logger

  alias Wardrik.Notice
  alias Wardrik.Notify
  alias Wardrik.Operations.Snapshot
  alias WardrikCore.Retry

  @key "notifier"
  @types ~w(wardrik.tool_call.started wardrik.run.interrupted wardrik.run.failed
            wardrik.run.completed wardrik.run.cancelled)

  @doc "Returns the notifier's children."
  @spec children(Wardrik.t()) :: [Supervisor.child_spec()]
  def children(wardrik) do
    supervisor = Module.concat(wardrik.name, Notify)

    durable =
      [
        name: supervisor,
        prefix: "notify/",
        backend: {WardrikStore.Durable, store: WardrikStore.scope(wardrik.store, "wardrik")},
        init_info: %{wardrik: wardrik}
      ]
      |> DurableServer.Supervisor.child_spec()
      |> Map.put(:id, Notify)

    [durable, {Wardrik.Notify.Standby, supervisor}]
  end

  @doc "Starts the notifier under `supervisor`, or finds where it already runs."
  @spec claim(atom(), timeout()) :: {:ok, {pid(), map()}} | {:error, term()}
  def claim(supervisor, timeout) do
    child = {__MODULE__, key: @key, initial_state: %{cursor: nil, calls: %{}}}
    DurableServer.Supervisor.ensure_started_child(supervisor, child, timeout: timeout)
  end

  @impl DurableServer
  def dump_state(state), do: Map.take(state, [:cursor, :calls])

  @impl DurableServer
  def load_state(_vsn, dumped), do: dumped

  @impl DurableServer
  def init(state, %{wardrik: wardrik}) do
    Process.flag(:trap_exit, true)
    :telemetry.execute([:wardrik, :notify, :started], %{}, %{wardrik: wardrik.name})
    cursor = state.cursor || WardrikEvents.head(Wardrik.events(wardrik), :all)
    {:ok, tasks} = Task.Supervisor.start_link()

    {:ok, follower} =
      Wardrik.Listener.start_link(Wardrik.Notify.Follower,
        wardrik: wardrik.name,
        types: @types,
        server: self()
      )

    {:ok,
     %{state | cursor: cursor}
     |> Map.merge(%{wardrik: wardrik, tasks: tasks, follower: follower}), permanent: true}
  end

  @impl DurableServer
  def handle_call(:cursor, _from, state), do: {:reply, state.cursor, state}

  def handle_call({:event, event, cursor}, _from, state) do
    state = taken(state, agent(event), event)
    {:reply, :ok, %{state | cursor: cursor}, sync: true}
  end

  @impl DurableServer
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  @impl DurableServer
  def terminate(_reason, %{follower: follower}) do
    Process.unlink(follower)
    Process.exit(follower, :kill)
  end

  def terminate(_reason, _state), do: :ok

  defp taken(state, agent, %{type: "wardrik.tool_call.started", data: %{"tool" => tool}}) do
    %{"id" => id} = call = tool["call"]

    update_in(
      state.calls,
      &Map.update(&1, agent, %{id => call["arguments"]}, fn calls ->
        Map.put(calls, id, call["arguments"])
      end)
    )
  end

  defp taken(state, agent, %{type: "wardrik.run.interrupted", data: data} = event) do
    ids = Enum.map(data["interrupts"], & &1["id"])

    case waiting(state, agent, ids) do
      [] -> state
      calls -> told(state, agent, notice(event, :parked, calls: calls))
    end
  end

  defp taken(state, agent, %{type: "wardrik.run.failed", data: data} = event),
    do:
      state
      |> told(agent, notice(event, :failed, reason: data["error"]["message"]))
      |> ended(agent)

  defp taken(state, agent, %{type: "wardrik.run.completed", data: data} = event),
    do:
      state
      |> told(agent, notice(event, :finished, text: Wardrik.Reply.text(data["messages"])))
      |> ended(agent)

  defp taken(state, agent, _cancelled), do: ended(state, agent)

  defp ended(state, agent), do: %{state | calls: Map.delete(state.calls, agent)}

  defp notice(event, kind, fields),
    do:
      struct!(
        Notice,
        [agent: event.agent, conversation: event.conversation, kind: kind, at: event.time] ++
          fields
      )

  defp waiting(state, agent, ids) do
    case Snapshot.known(state.wardrik, agent) do
      :ok ->
        for interrupt <- interrupts(state.wardrik, agent),
            interrupt.id in ids,
            do: %{
              interrupt: interrupt,
              arguments: get_in(state.calls, [agent, interrupt.tool_call_id])
            }

      {:error, _gone} ->
        []
    end
  end

  defp interrupts(wardrik, agent) do
    wardrik
    |> Wardrik.events()
    |> WardrikEvents.activity(agent)
    |> Snapshot.interrupts()
    |> Enum.map(&Wardrik.Interrupt.from_json/1)
  end

  defp told(state, {agent, _conversation}, notice) do
    with {:ok, definition} <- Wardrik.Definitions.fetch(state.wardrik, agent),
         {:ok, resolved} <-
           Wardrik.Resolver.resolve(state.wardrik, %Wardrik.Resolver.Request{
             agent: agent,
             definition: definition
           }),
         defaults = Map.merge(state.wardrik.defaults, resolved.defaults),
         %{to: to, on: on} <- Notify.route(Map.merge(defaults, definition)),
         true <- notice.kind in on,
         do: Enum.each(to, &tell(state, &1, notice))

    state
  end

  defp tell(state, name, notice) do
    case Retry.run(state.wardrik.notify.retries, fn -> attempt(state, name, notice) end,
           transient: &failed/1,
           announce: &again(name, notice, &1)
         ) do
      {:ok, :ok} ->
        :ok

      {:ok, {:skip, why}} ->
        Logger.warning("#{notice.agent} notifies #{name}, #{why}.")

      {:spent, {:error, reason}, _tries} ->
        Logger.warning(couldnt(name, notice, reason) <> "; giving up.")
    end
  end

  defp attempt(state, name, notice) do
    task =
      Task.Supervisor.async_nolink(state.tasks, fn ->
        Notify.deliver(state.wardrik, name, notice)
      end)

    case Task.yield(task, :infinity) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end

  defp failed({:error, reason}), do: reason
  defp failed(_delivered), do: nil

  defp again(name, notice, %{reason: reason}),
    do: Logger.warning(couldnt(name, notice, reason) <> "; trying again.")

  defp couldnt(name, notice, reason),
    do: "Couldn't tell #{name} that #{notice.agent} #{notice.kind}: #{inspect(reason)}"

  defp agent(%Wardrik.Event{agent: agent, conversation: conversation}), do: {agent, conversation}
end

defmodule Wardrik.Notify.Follower do
  @moduledoc false

  use Wardrik.Listener

  @impl Wardrik.Listener
  def handle(event, listener),
    do: GenServer.call(listener.options[:server], {:event, event, listener.cursor}, :infinity)

  @impl Wardrik.Listener
  def cursor(listener), do: GenServer.call(listener.options[:server], :cursor)
end
