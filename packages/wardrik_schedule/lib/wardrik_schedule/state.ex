defmodule WardrikSchedule.State do
  @moduledoc """
  A running schedule as data: the agent it asks, the schedule, when it runs
  next, when it last fired and what came of it, and its source's cursor.

  Every move is a function of the state and the time, so `WardrikSchedule.Server`
  only carries out what these answer.
  """

  @enforce_keys [:agent, :schedule, :next_at]
  defstruct [:agent, :schedule, :next_at, :last_at, :last_outcome, :cursor]

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentID.t(),
          schedule: WardrikSchedule.t(),
          next_at: DateTime.t(),
          last_at: DateTime.t() | nil,
          last_outcome: WardrikSchedule.outcome() | nil,
          cursor: WardrikSchedule.Source.cursor() | nil
        }

  # How late a run may be and still count as on time rather than missed: a
  # timer fires a little after the time it was armed for, and a node restarts
  # in seconds.
  @grace_ms :timer.minutes(1)

  @doc "A schedule for `agent` that has not run yet."
  @spec new(Wardrik.AgentID.t(), WardrikSchedule.t(), DateTime.t()) :: t()
  def new(%Wardrik.AgentID{} = agent, %WardrikSchedule{} = schedule, now) do
    %__MODULE__{agent: agent, schedule: schedule, next_at: WardrikSchedule.next(schedule, now)}
  end

  @doc """
  The state with `schedule` in place. A new `every` goes on from `now`; the
  same one keeps the next run already set.
  """
  @spec configure(t(), WardrikSchedule.t(), DateTime.t()) :: t()
  def configure(
        %__MODULE__{schedule: %{every: every}} = state,
        %WardrikSchedule{every: every} = schedule,
        _now
      ),
      do: %{state | schedule: schedule}

  def configure(%__MODULE__{} = state, %WardrikSchedule{} = schedule, now),
    do: %{state | schedule: schedule, next_at: WardrikSchedule.next(schedule, now)}

  @doc """
  What the schedule should do at `now`:

    * `{:wait, ms}` - nothing yet, for `ms`
    * `{:fire, state}` - fire now, with the next run set from `now`
    * `{:skip, state}` - let an overdue run go, as `missed: :skip` says, with
      the next run set from `now`
  """
  @spec due(t(), DateTime.t()) :: {:wait, non_neg_integer()} | {:fire, t()} | {:skip, t()}
  def due(%__MODULE__{} = state, now) do
    late = DateTime.diff(now, state.next_at, :millisecond)
    advanced = %{state | next_at: WardrikSchedule.next(state.schedule, now)}

    cond do
      late < 0 ->
        {:wait, -late}

      late <= @grace_ms or state.schedule.missed == :run_once ->
        {:fire, %{advanced | last_at: now}}

      true ->
        {:skip, %{advanced | last_outcome: :missed}}
    end
  end

  @doc "The state after a firing came to `outcome`."
  @spec fired(t(), WardrikSchedule.outcome()) :: t()
  def fired(%__MODULE__{} = state, outcome), do: %{state | last_outcome: outcome}

  @doc "What the registry shows for the schedule. See `WardrikSchedule.Status`."
  @spec meta(t()) :: map()
  def meta(%__MODULE__{} = state) do
    %{
      agent: state.agent,
      name: state.schedule.name,
      every: state.schedule.every,
      next_at: state.next_at,
      last_at: state.last_at,
      last_outcome: state.last_outcome
    }
  end
end
