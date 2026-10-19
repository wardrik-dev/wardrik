defmodule Wardrik.Agent.State.View do
  @moduledoc """
  What a `Wardrik.Agent.State` shows of itself: its status to a caller, its
  meta to the fleet, and a snapshot to a client attaching.
  """

  alias Wardrik.Agent.Snapshot
  alias Wardrik.Agent.State
  alias Wardrik.Agent.State.Due
  alias Wardrik.Agent.State.Running
  alias Wardrik.Agent.State.Stored
  alias Wardrik.Agent.State.Waiting

  @typedoc """
  Whether a turn is in flight, how many messages are waiting behind it, the
  model, and what it is doing now.
  """
  @type status() :: %{
          state: :idle | :running | :parked,
          pending: non_neg_integer(),
          model: term(),
          activity: Wardrik.Agent.Activity.t()
        }

  @typedoc """
  What the fleet shows for an agent: what it is doing, how much waits behind
  it, the calls it is waiting on, and how the last turn ended.
  """
  @type meta() :: %{
          status: :idle | :running | :parked,
          pending: non_neg_integer(),
          waiting_on: [String.t()],
          outcome: State.outcome()
        }

  @doc "What the agent is doing, how much is queued behind it, and the model it runs."
  @spec status(State.t()) :: status()
  def status(%State{} = state) do
    %{
      state: activity(state.mode),
      pending: length(state.pending),
      model: state.config.model_spec,
      activity: state.activity
    }
  end

  # A turn that is due starts on the next message: running, not idle.
  defp activity(%Running{}), do: :running
  defp activity(%Due{}), do: :running
  defp activity(%Waiting{}), do: :parked
  defp activity(:idle), do: :idle

  @doc """
  What `Wardrik.Fleet` reports about the agent, republished on every
  transition. Replicated to every node, so it holds nothing private.
  """
  @spec meta(State.t()) :: meta()
  def meta(%State{} = state) do
    %{state: activity, pending: pending} = status(state)

    %{
      status: activity,
      pending: pending,
      waiting_on: Enum.map(State.waiting_on(state), fn {call, _prompt} -> call.name end),
      outcome: state.outcome
    }
  end

  @doc """
  What `Wardrik.Fleet` reports about an agent that is asleep, read from what it
  wrote down as it stopped. It was idle or parked, since an agent sleeps only
  then.
  """
  @spec meta_at_rest(Stored.t()) :: meta()
  def meta_at_rest(dumped) do
    waiting = Stored.waiting_on(dumped)

    %{
      status: if(waiting == [], do: :idle, else: :parked),
      pending: length(dumped.pending),
      waiting_on: Enum.map(waiting, fn {call, _prompt} -> call.name end),
      outcome: dumped.outcome
    }
  end

  @doc """
  An atomic attachment snapshot; generation survives restarts but not
  deletion. Carries the last sequence its log has written, so the client can
  follow the log from there.
  """
  @spec snapshot(State.t()) :: Snapshot.t()
  def snapshot(%State{} = state) do
    %Snapshot{
      agent: state.agent_id,
      generation: state.generation,
      status: status(state),
      history: state.history,
      parked: State.waiting_on(state),
      trace_id: trace_id(state.mode),
      outcome: state.outcome,
      sequence: state.log.head,
      labels: state.labels
    }
  end

  defp trace_id(%Running{run: run}), do: run.source.trace.trace_id
  defp trace_id(%Waiting{source: source}), do: source.trace.trace_id
  defp trace_id(%Due{source: %{trace: trace}}), do: trace.trace_id
  defp trace_id(_mode), do: nil
end
