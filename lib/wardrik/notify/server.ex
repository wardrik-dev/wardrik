defmodule Wardrik.Notify.Server do
  @moduledoc false

  # Each node tells of the agents it runs. Their events reach it through `Wardrik.Notify.Sink`,
  # in the order each agent wrote them.

  use GenServer

  require Logger

  alias Wardrik.Notice
  alias Wardrik.Notify
  alias Wardrik.Operations.Snapshot
  alias WardrikCore.Retry

  @doc "Starts the node's notifier."
  @spec start_link(Wardrik.t()) :: GenServer.on_start()
  def start_link(wardrik), do: GenServer.start_link(__MODULE__, wardrik, name: name(wardrik.name))

  @doc "Returns the name of the notifier for the Wardrik named `name`."
  @spec name(atom()) :: atom()
  def name(name), do: Module.concat(name, Notify)

  @impl GenServer
  def init(wardrik) do
    {:ok, tasks} = Task.Supervisor.start_link()
    {:ok, %{wardrik: wardrik, tasks: tasks, calls: %{}}}
  end

  @impl GenServer
  def handle_cast({:event, json}, state) do
    event = Wardrik.Event.from_json(json)
    {:noreply, taken(state, agent(event), event)}
  end

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
