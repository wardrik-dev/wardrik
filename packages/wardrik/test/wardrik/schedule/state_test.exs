defmodule Wardrik.Schedule.StateTest do
  use ExUnit.Case, async: true

  alias Wardrik.Schedule
  alias Wardrik.Schedule.State

  @created ~U[2026-09-24 09:00:00Z]

  defp state(opts \\ []) do
    schedule =
      Schedule.new("sweep", Keyword.merge([every: "*/30 * * * *", prompt: "Look."], opts))

    State.new(Wardrik.AgentID.parse!("default/triage"), schedule, @created)
  end

  describe "new/3" do
    test "sets the first run from the time it is created" do
      assert state().next_at == ~U[2026-09-24 09:30:00Z]
    end
  end

  describe "due/2" do
    test "waits for a run still to come" do
      assert {:wait, 60_000} = State.due(state(), ~U[2026-09-24 09:29:00Z])
    end

    test "fires a run that is due, and sets the next one from now" do
      assert {:fire, next} = State.due(state(), ~U[2026-09-24 09:30:00.005Z])
      assert next.next_at == ~U[2026-09-24 10:00:00Z]
      assert next.last_at == ~U[2026-09-24 09:30:00.005Z]
    end

    test "fires a run a little late as it would one on time" do
      assert {:fire, _next} = State.due(state(missed: :skip), ~U[2026-09-24 09:30:40Z])
    end

    test "fires an overdue run once, and goes on from now, by default" do
      assert {:fire, next} = State.due(state(), ~U[2026-09-24 13:47:00Z])
      assert next.next_at == ~U[2026-09-24 14:00:00Z]
    end

    test "lets an overdue run go when the schedule skips what it missed" do
      assert {:skip, next} = State.due(state(missed: :skip), ~U[2026-09-24 13:47:00Z])
      assert next.next_at == ~U[2026-09-24 14:00:00Z]
      assert next.last_outcome == :missed
      assert next.last_at == nil
    end
  end

  describe "configure/3" do
    test "keeps the next run when the schedule keeps its clock" do
      state = state()
      reworded = %{state.schedule | prompt: "Look again."}

      configured = State.configure(state, reworded, ~U[2026-09-24 09:20:00Z])
      assert configured.next_at == ~U[2026-09-24 09:30:00Z]
      assert configured.schedule.prompt == "Look again."
    end

    test "goes on from now when the clock changes" do
      state = state()
      hourly = Schedule.new("sweep", every: "@hourly", prompt: "Look.")

      assert State.configure(state, hourly, ~U[2026-09-24 09:20:00Z]).next_at ==
               ~U[2026-09-24 10:00:00Z]
    end
  end
end
