defmodule Wardrik.ScheduleTest do
  use ExUnit.Case, async: false

  alias Wardrik.Agent.Spec
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.Schedule
  alias Wardrik.Test.AgentRunners

  # Short enough to fire within an assert_receive, long enough that a test
  # sees each firing it waits for.
  @every {:interval, 50}

  setup do
    key = Fleet.key("scheduled-#{System.unique_integer([:positive])}")
    on_exit(fn -> Fleet.forget(key) end)
    %{key: key}
  end

  defp spawn_agent(key, runner) do
    {:ok, _pid} = Fleet.spawn(key, runner: runner)
    :ok = Event.Bus.subscribe(key, level: :lifecycle)
  end

  describe "new/2" do
    test "reads a duration as an interval" do
      assert %Schedule{every: {:interval, 1_800_000}} =
               Schedule.new("sweep", every: "30m", prompt: "Look.")

      assert %Schedule{every: {:interval, 86_400_000}} =
               Schedule.new("sweep", every: "1d", prompt: "Look.")
    end

    test "keeps a cron expression as the text it read" do
      assert %Schedule{every: {:cron, "*/30 * * * *"}} =
               Schedule.new("sweep", every: " */30 * * * * ", prompt: "Look.")
    end

    test "refuses what it cannot read" do
      assert_raise ArgumentError, ~r/shorter than a minute/, fn ->
        Schedule.new("sweep", every: "30s", prompt: "Look.")
      end

      assert_raise ArgumentError, ~r/every: .*not five fields/, fn ->
        Schedule.new("sweep", every: "every half hour", prompt: "Look.")
      end

      assert_raise ArgumentError, ~r/prompt is a string/, fn ->
        Schedule.new("sweep", every: "30m")
      end

      assert_raise ArgumentError, ~r/may not contain "\/"/, fn ->
        Schedule.new("a/b", every: "30m", prompt: "Look.")
      end

      assert_raise ArgumentError, ~r/overlap is one of :skip, :queue/, fn ->
        Schedule.new("sweep", every: "30m", prompt: "Look.", overlap: :interrupt)
      end
    end
  end

  describe "decode/2" do
    test "reads a schedule's fields written as text" do
      assert {:ok,
              %Schedule{
                name: "sweep",
                every: {:cron, "*/30 * * * *"},
                prompt: "Look.",
                overlap: :queue,
                missed: :skip,
                jitter: 30_000
              }} =
               Schedule.decode("sweep", %{
                 "every" => "*/30 * * * *",
                 "prompt" => "Look.",
                 "overlap" => "queue",
                 "missed" => "skip",
                 "jitter" => 30
               })

      assert {:ok, %Schedule{every: {:interval, 1_800_000}, overlap: :skip, jitter: 0}} =
               Schedule.decode("sweep", %{"every" => "30m", "prompt" => "Look."})
    end

    test "says what does not read" do
      for {fields, message} <- [
            {%{"when" => "now"},
             "when is not a setting; expected every, prompt, overlap, missed or jitter"},
            {%{"prompt" => "Look."}, ~s(every is a cron expression, or a duration such as "30m")},
            {%{"every" => "30m", "prompt" => "Look.", "overlap" => "interrupt"},
             "overlap is one of skip, queue"},
            {%{"every" => "30m", "prompt" => "Look.", "missed" => 1},
             "missed is one of run_once, skip"},
            {%{"every" => "30m", "prompt" => "Look.", "jitter" => 1.5},
             "jitter is a whole number of seconds"},
            {%{"every" => "30s", "prompt" => "Look."}, ~s(every: "30s" is shorter than a minute)}
          ] do
        assert Schedule.decode("sweep", fields) == {:error, message}
      end
    end
  end

  describe "firing" do
    test "asks the agent, and says so on its topic", %{key: key} do
      spawn_agent(key, {AgentRunners, :echo, [self(), "done"]})

      {:ok, _pid} = Schedule.put(key, "tick", every: @every, prompt: "Check the queue.")

      assert_receive {:turn, [user: "Check the queue."]}
      assert_receive %Event{payload: {:schedule_fired, "tick", :asked}}
    end

    test "leaves a running agent be when it skips overlaps", %{key: key} do
      spawn_agent(key, {AgentRunners, :blocking, [self(), "done"]})

      {:ok, _pid} = Schedule.put(key, "tick", every: @every, prompt: "Check the queue.")

      assert_receive {:turn, _context, turn}
      assert_receive %Event{payload: {:schedule_fired, "tick", :asked}}
      assert_receive %Event{payload: {:schedule_fired, "tick", :busy}}
      send(turn, :release)
    end

    test "asks a running agent anyway when it queues overlaps", %{key: key} do
      spawn_agent(key, {AgentRunners, :blocking, [self(), "done"]})

      {:ok, _pid} =
        Schedule.put(key, "tick", every: @every, prompt: "Check the queue.", overlap: :queue)

      assert_receive {:turn, _context, turn}
      assert_receive %Event{payload: {:schedule_fired, "tick", :asked}}
      assert_receive %Event{payload: {:schedule_fired, "tick", :asked}}
      send(turn, :release)
    end

    test "says there is no agent to ask when none runs under the key", %{key: key} do
      :ok = Event.Bus.subscribe(key, level: :lifecycle)

      {:ok, _pid} = Schedule.put(key, "tick", every: @every, prompt: "Check the queue.")

      assert_receive %Event{payload: {:schedule_fired, "tick", :no_agent}}
    end
  end

  describe "list/1 and sync/2" do
    test "lists an agent's schedules with their next run", %{key: key} do
      {:ok, _pid} = Schedule.put(key, "sweep", every: "@daily", prompt: "Look.")

      assert [%Schedule.Status{name: "sweep", agent: ^key, every: {:cron, "@daily"}} = status] =
               Schedule.for_agent(key)

      assert DateTime.compare(status.next_at, DateTime.utc_now()) == :gt
    end

    test "puts the schedules it is given and deletes the rest", %{key: key} do
      {:ok, _pid} = Schedule.put(key, "old", every: "@daily", prompt: "Look.")
      daily = Schedule.new("new", every: "@daily", prompt: "Look.")

      assert :ok = Schedule.sync(key, [daily])
      assert [%{name: "new"}] = Schedule.for_agent(key)
    end
  end

  describe "the fleet" do
    test "put/1 brings an agent's schedules to its spec, or leaves them, and forget/1 deletes them" do
      name = "specced-#{System.unique_integer([:positive])}"
      daily = Schedule.new("sweep", every: "@daily", prompt: "Look.")
      spec = Spec.new(name: name, schedules: [daily])
      key = Spec.key(spec)

      {:ok, _pid} = Fleet.put(spec)
      assert [%{name: "sweep"}] = Schedule.for_agent(key)

      {:ok, _pid} = Fleet.put(%{spec | schedules: nil})
      assert [%{name: "sweep"}] = Schedule.for_agent(key)

      {:ok, _pid} = Fleet.put(%{spec | schedules: []})
      assert Schedule.for_agent(key) == []

      {:ok, _pid} = Fleet.put(spec)
      assert :ok = Fleet.forget(key)
      assert Schedule.for_agent(key) == []
    end
  end
end
