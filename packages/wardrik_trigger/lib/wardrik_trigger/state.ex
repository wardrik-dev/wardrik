defmodule WardrikTrigger.State do
  @moduledoc """
  A running trigger as data: the agent it asks, the trigger, when it runs
  next, when it last fired and what came of it, and its source's cursor.

  Every move is a function of the state and the time, so `WardrikTrigger.Server`
  only carries out what these answer.
  """

  @enforce_keys [:agent, :trigger, :next_at]
  defstruct [:agent, :trigger, :next_at, :last_at, :last_outcome, :cursor]

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentID.t(),
          trigger: WardrikTrigger.t(),
          next_at: DateTime.t(),
          last_at: DateTime.t() | nil,
          last_outcome: WardrikTrigger.outcome() | nil,
          cursor: WardrikTrigger.Source.cursor() | nil
        }

  # How late a run may be and still count as on time rather than missed: a
  # timer fires a little after the time it was armed for, and a node restarts
  # in seconds.
  @grace_ms :timer.minutes(1)

  @doc "A trigger for `agent` that has not run yet."
  @spec new(Wardrik.AgentID.t(), WardrikTrigger.t(), DateTime.t()) :: t()
  def new(%Wardrik.AgentID{} = agent, %WardrikTrigger{} = trigger, now) do
    %__MODULE__{agent: agent, trigger: trigger, next_at: WardrikTrigger.next(trigger, now)}
  end

  @doc """
  The state with `trigger` in place. A new `every` goes on from `now`; the
  same one keeps the next run already set.
  """
  @spec configure(t(), WardrikTrigger.t(), DateTime.t()) :: t()
  def configure(
        %__MODULE__{trigger: %{every: every}} = state,
        %WardrikTrigger{every: every} = trigger,
        _now
      ),
      do: %{state | trigger: trigger}

  def configure(%__MODULE__{} = state, %WardrikTrigger{} = trigger, now),
    do: %{state | trigger: trigger, next_at: WardrikTrigger.next(trigger, now)}

  @doc """
  What the trigger should do at `now`:

    * `{:wait, ms}` - nothing yet, for `ms`
    * `{:fire, state}` - fire now, with the next run set from `now`
    * `{:skip, state}` - let an overdue run go, as `missed: :skip` says, with
      the next run set from `now`
  """
  @spec due(t(), DateTime.t()) :: {:wait, non_neg_integer()} | {:fire, t()} | {:skip, t()}
  def due(%__MODULE__{} = state, now) do
    late = DateTime.diff(now, state.next_at, :millisecond)
    advanced = %{state | next_at: WardrikTrigger.next(state.trigger, now)}

    cond do
      late < 0 ->
        {:wait, -late}

      late <= @grace_ms or state.trigger.missed == :run_once ->
        {:fire, %{advanced | last_at: now}}

      true ->
        {:skip, %{advanced | last_outcome: :missed}}
    end
  end

  @doc "The state after a firing came to `outcome`."
  @spec fired(t(), WardrikTrigger.outcome()) :: t()
  def fired(%__MODULE__{} = state, outcome), do: %{state | last_outcome: outcome}

  @doc "What the registry shows for the trigger. See `WardrikTrigger.Status`."
  @spec meta(t()) :: map()
  def meta(%__MODULE__{} = state) do
    %{
      agent: state.agent,
      name: state.trigger.name,
      schedule: WardrikTrigger.schedule(state.trigger.every),
      next: [state.next_at],
      paths: [],
      last_at: state.last_at,
      last_outcome: state.last_outcome
    }
  end
end
