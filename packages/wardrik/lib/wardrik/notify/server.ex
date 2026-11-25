defmodule Wardrik.Notify.Server do
  @moduledoc false

  # Each node tells of the agents it runs. Their events reach it through `Wardrik.Notify.Sink`,
  # in the order each agent wrote them. A run someone asked for answers them where they asked,
  # so its finish is told to no one: `sent` holds the messages that carry a sender until a run
  # takes them, and `asked` the runs that took one, until they end.

  use GenServer

  alias Wardrik.Notice
  alias Wardrik.Notify
  alias Wardrik.Operations.Snapshot
  alias WardrikCore.Retry

  require Logger

  @doc "Starts the node's notifier."
  @spec start_link(Wardrik.t()) :: GenServer.on_start()
  def start_link(wardrik), do: GenServer.start_link(__MODULE__, wardrik, name: name(wardrik.name))

  @doc "Returns the name of the notifier for the Wardrik named `name`."
  @spec name(atom()) :: atom()
  def name(name), do: Module.concat(name, Notify)

  @impl GenServer
  def init(wardrik) do
    {:ok, tasks} = Task.Supervisor.start_link()
    {:ok, %{wardrik: wardrik, tasks: tasks, sent: MapSet.new(), asked: MapSet.new()}}
  end

  @impl GenServer
  def handle_cast({:event, %Wardrik.Event{} = event}, state),
    do: {:noreply, take(state, agent(event), event)}

  defp take(state, _agent, %{type: "wardrik.message.created", data: %{"sender" => _who} = data}),
    do: %{state | sent: MapSet.put(state.sent, data["message"]["id"])}

  defp take(state, _agent, %{type: "wardrik.message.created"}), do: state

  defp take(state, _agent, %{type: "wardrik.run.started", data: %{"run" => run}}) do
    ids = Map.get(run, "message_ids", [])
    asked? = Enum.any?(ids, &MapSet.member?(state.sent, &1))
    state = %{state | sent: Enum.reduce(ids, state.sent, &MapSet.delete(&2, &1))}

    if asked?, do: %{state | asked: MapSet.put(state.asked, run["id"])}, else: state
  end

  defp take(state, agent, %{type: "wardrik.run.interrupted", data: data} = event) do
    ids = Enum.map(data["interrupts"], & &1["id"])

    case waiting(state, agent, ids) do
      [] -> state
      calls -> handle_tell(state, agent, notice(event, :parked, calls: calls))
    end
  end

  defp take(state, agent, %{type: "wardrik.run.failed", data: data} = event) do
    state
    |> forget_run(data)
    |> handle_tell(agent, notice(event, :failed, reason: data["error"]["message"]))
  end

  defp take(state, agent, %{type: "wardrik.run.completed", data: data} = event) do
    if MapSet.member?(state.asked, data["run"]["id"]),
      do: forget_run(state, data),
      else:
        handle_tell(
          state,
          agent,
          notice(event, :finished, text: Wardrik.Reply.text(data["messages"]))
        )
  end

  defp take(state, _agent, %{type: type, data: data})
       when type in ["wardrik.run.cancelled", "wardrik.run.deadline_exceeded"],
       do: forget_run(state, data)

  defp forget_run(state, %{"run" => run}),
    do: %{state | asked: MapSet.delete(state.asked, run["id"])}

  defp notice(event, kind, fields),
    do:
      struct!(
        Notice,
        [agent: event.agent, conversation: event.conversation, kind: kind, at: event.time] ++
          fields
      )

  defp waiting(state, agent, ids) do
    case Snapshot.check_known(state.wardrik, agent) do
      :ok ->
        for interrupt <- interrupts(state.wardrik, agent),
            interrupt.id in ids,
            do: %{interrupt: interrupt, arguments: interrupt.arguments}

      {:error, _gone} ->
        []
    end
  end

  defp interrupts(wardrik, agent) do
    wardrik
    |> Wardrik.events()
    |> Wardrik.EventLog.activity(agent)
    |> Snapshot.interrupts()
    |> Enum.map(&Wardrik.Interrupt.from_json/1)
  end

  defp handle_tell(state, {agent, _conversation}, notice) do
    with {:ok, definition} <- Wardrik.Definitions.fetch(state.wardrik, agent),
         {:ok, resolved} <-
           Wardrik.Resolver.resolve(state.wardrik, %Wardrik.Resolver.Request{
             agent: agent,
             definition: definition
           }),
         defaults = Map.merge(state.wardrik.defaults, resolved.defaults),
         merged = Map.merge(defaults, definition),
         false <- quiet?(notice) do
      named = %{notice | name: merged["display_name"]}

      targets =
        for route <- Notify.routes(merged),
            notice.kind in route.on,
            Notify.Judge.decide(state.wardrik, named, route.judge) == :send,
            to <- route.to,
            uniq: true,
            do: to

      Enum.each(targets, &tell(state, &1, named))
    end

    state
  end

  defp quiet?(%Notice{kind: :finished, text: text}), do: Wardrik.Reply.quiet?(text)
  defp quiet?(_notice), do: false

  defp tell(state, name, notice) do
    case Retry.run(state.wardrik.notify.retries, fn -> attempt(state, name, notice) end,
           transient: &fail/1,
           announce: &again(name, notice, &1)
         ) do
      {:ok, :ok} ->
        :ok

      {:ok, {:skip, why}} ->
        Logger.warning("#{label_agent(notice)} notifies #{name}, #{why}.")

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

  defp fail({:error, reason}), do: reason
  defp fail(_delivered), do: nil

  defp again(name, notice, %{reason: reason}),
    do: Logger.warning(couldnt(name, notice, reason) <> "; trying again.")

  defp couldnt(name, notice, reason),
    do: "Couldn't tell #{name} that #{label_agent(notice)} #{notice.kind}: #{inspect(reason)}"

  defp label_agent(%Notice{name: nil, agent: agent}), do: agent
  defp label_agent(%Notice{name: name}), do: name

  defp agent(%Wardrik.Event{agent: agent, conversation: conversation}), do: {agent, conversation}
end
