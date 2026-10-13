defmodule WardrikTrigger.Webhook.Server do
  @moduledoc """
  The process behind one `WardrikTrigger.Webhook`: it waits for requests,
  checks each one's signature, and asks the agent about each delivery once.

  It keeps the IDs of the last 500 deliveries it asked about, written
  down before the agent is asked, so a delivery the sender tries again is
  answered as seen, and the agent is asked about it at most once. A delivery
  it cannot make now, because the agent is busy and `overlap: :skip` leaves
  it be, or no agent runs under the ID, is not written down, so the sender's
  next try makes it. Every delivery to one trigger passes through this one
  process, so two at once are taken in turn.

  Started by `WardrikTrigger.put/2` under the supervisor `WardrikTrigger`
  runs.
  """

  use DurableServer, vsn: 1

  alias WardrikTrigger.Delivery
  alias WardrikTrigger.Webhook

  require Logger

  @seen 500

  @enforce_keys [:agent, :hook]
  defstruct [:agent, :hook, :last_at, :last_outcome, seen: []]

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentID.t(),
          hook: Webhook.t(),
          last_at: DateTime.t() | nil,
          last_outcome: WardrikTrigger.outcome() | nil,
          seen: [String.t()]
        }

  @impl DurableServer
  def dump_state(%__MODULE__{} = state), do: Map.from_struct(state)

  @impl DurableServer
  def load_state(_old_vsn, dumped), do: struct!(__MODULE__, dumped)

  @impl DurableServer
  def init(%__MODULE__{} = state) do
    :ok = WardrikTrigger.join(state.agent, state.hook)
    {:ok, state, meta: meta(state), permanent: true}
  end

  @impl DurableServer
  def handle_call({:configure, %Webhook{} = hook}, _from, state) do
    next = %{state | hook: hook}
    {:reply, :ok, next, meta: meta(next), sync: true}
  end

  def handle_call({:deliver, request}, _from, %__MODULE__{agent: agent, hook: hook} = state) do
    with {:ok, item} <- Webhook.received(hook, request, agent),
         false <- item.id in state.seen,
         {:ok, pid} <- Delivery.ready(agent, hook.overlap) do
      next = %{
        state
        | seen: Enum.take([item.id | state.seen], @seen),
          last_at: DateTime.utc_now()
      }

      {:reply, {:ok, :asked}, next, {:continue, {:ask, pid, item}}, meta: meta(next), sync: true}
    else
      true ->
        {:reply, {:ok, :seen}, state}

      {:error, :forbidden, message} = refused ->
        Logger.warning("trigger #{agent}//#{hook.name} refused a request: #{message}")
        {:reply, refused, state}

      {:error, :unavailable, _message} = refused ->
        {:reply, refused, state}

      outcome ->
        Delivery.announce(agent, hook.name, outcome)
        next = %{state | last_outcome: outcome}
        {:reply, {:error, :unavailable, unavailable(outcome)}, next, meta: meta(next)}
    end
  end

  # Runs once the delivery's ID is written down, so a crash from here on
  # loses this delivery rather than asking about it twice.
  @impl DurableServer
  def handle_continue({:ask, pid, item}, %__MODULE__{agent: agent, hook: hook} = state) do
    :ok = Delivery.ask(pid, hook.prompt, [item])
    Delivery.announce(agent, hook.name, :asked)
    next = %{state | last_outcome: :asked}
    {:noreply, next, meta: meta(next), sync: true}
  end

  defp unavailable(:busy), do: "The agent is busy, and this trigger skips what arrives meanwhile."
  defp unavailable(:no_agent), do: "No agent runs under this key now."
  defp unavailable(:failed), do: "The agent could not be asked now."

  defp meta(%__MODULE__{} = state) do
    %{
      agent: state.agent,
      name: state.hook.name,
      schedule: "on request",
      next: [],
      paths: [Webhook.path(state.agent, state.hook.name)],
      last_at: state.last_at,
      last_outcome: state.last_outcome
    }
  end
end
