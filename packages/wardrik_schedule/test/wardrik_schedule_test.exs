defmodule WardrikScheduleTest.Watch do
  @moduledoc false
  @behaviour WardrikSchedule.Source

  # Answers each check with the next of the answers its test hands it, each a
  # function of the cursor, and with nothing new once they run out.

  @impl WardrikSchedule.Source
  def decode(%{"watch" => name} = fields) when map_size(fields) == 1 and is_binary(name),
    do: {:ok, name}

  def decode(_fields), do: {:error, "watch names the answers a test hands it"}

  @impl WardrikSchedule.Source
  def encode(name), do: %{"watch" => name}

  @impl WardrikSchedule.Source
  def check(name, cursor, _agent) do
    answer =
      Agent.get_and_update(String.to_existing_atom(name), fn
        [next | rest] -> {next, rest}
        [] -> {fn cursor -> {:ok, [], cursor} end, []}
      end)

    answer.(cursor)
  end

  def answers(name, answers), do: Agent.start_link(fn -> answers end, name: name)
end

defmodule WardrikScheduleTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.LLM.Turn
  alias Wardrik.Test.AgentRunners
  alias WardrikSchedule.Item
  alias WardrikScheduleTest.Watch

  # Short enough to fire within an assert_receive, long enough that a test
  # sees each firing it waits for.
  @every {:interval, 50}

  setup do
    key = Wardrik.Test.Fleet.id("scheduled")

    on_exit(fn ->
      :ok = WardrikSchedule.sync(key, [])
      Fleet.forget(key)
    end)

    %{key: key}
  end

  @doc "Reports the message and labels a turn began with, then answers."
  def labelled(test_pid, %Turn{} = turn) do
    [%{content: [%{text: text}]} | _] = Enum.reverse(turn.context.messages)
    send(test_pid, {:asked, text, turn.labels})
    Turn.done(turn, [Context.assistant("done")])
  end

  defp watching(_context) do
    Application.put_env(:wardrik_schedule, :wardrik_schedule_sources, watch: Watch)
    on_exit(fn -> Application.delete_env(:wardrik_schedule, :wardrik_schedule_sources) end)
  end

  defp spawn_agent(key, runner) do
    {:ok, _pid} = Fleet.spawn(key, runner: runner)
    :ok = Event.Bus.subscribe(key, level: :lifecycle)
  end

  describe "new/2" do
    test "reads a duration as an interval" do
      assert %WardrikSchedule{every: {:interval, 1_800_000}} =
               WardrikSchedule.new("sweep", every: "30m", prompt: "Look.")

      assert %WardrikSchedule{every: {:interval, 86_400_000}} =
               WardrikSchedule.new("sweep", every: "1d", prompt: "Look.")
    end

    test "keeps a cron expression as the text it read" do
      assert %WardrikSchedule{every: {:cron, "*/30 * * * *"}} =
               WardrikSchedule.new("sweep", every: " */30 * * * * ", prompt: "Look.")
    end

    test "refuses what it cannot read" do
      assert_raise ArgumentError, ~r/shorter than a minute/, fn ->
        WardrikSchedule.new("sweep", every: "30s", prompt: "Look.")
      end

      assert_raise ArgumentError, ~r/every: .*not five fields/, fn ->
        WardrikSchedule.new("sweep", every: "every half hour", prompt: "Look.")
      end

      assert_raise ArgumentError, ~r/prompt is a string/, fn ->
        WardrikSchedule.new("sweep", every: "30m")
      end

      assert_raise ArgumentError, ~r/may not contain "\/"/, fn ->
        WardrikSchedule.new("a/b", every: "30m", prompt: "Look.")
      end

      assert_raise ArgumentError, ~r/overlap is one of :skip, :queue/, fn ->
        WardrikSchedule.new("sweep", every: "30m", prompt: "Look.", overlap: :interrupt)
      end
    end
  end

  describe "encode/1" do
    test "writes a schedule as decode/2 reads it" do
      for fields <- [
            %{
              "every" => "*/30 * * * *",
              "prompt" => "Look.",
              "overlap" => "queue",
              "jitter" => 30
            },
            %{"every" => "90m", "prompt" => "Look.", "missed" => "skip"}
          ] do
        {:ok, schedule} = WardrikSchedule.decode("sweep", fields)
        encoded = WardrikSchedule.encode(schedule)

        assert {:ok, ^schedule} = WardrikSchedule.decode("sweep", Map.delete(encoded, "name"))
        assert encoded["name"] == "sweep"
      end

      assert %{"every" => "2h", "overlap" => "skip", "missed" => "run_once", "jitter" => 0} =
               WardrikSchedule.encode(
                 WardrikSchedule.new("sweep", every: "120m", prompt: "Look.")
               )
    end
  end

  describe "decode/2" do
    test "reads a schedule's fields written as text" do
      assert {:ok,
              %WardrikSchedule{
                name: "sweep",
                every: {:cron, "*/30 * * * *"},
                prompt: "Look.",
                overlap: :queue,
                missed: :skip,
                jitter: 30_000
              }} =
               WardrikSchedule.decode("sweep", %{
                 "every" => "*/30 * * * *",
                 "prompt" => "Look.",
                 "overlap" => "queue",
                 "missed" => "skip",
                 "jitter" => 30
               })

      assert {:ok, %WardrikSchedule{every: {:interval, 1_800_000}, overlap: :skip, jitter: 0}} =
               WardrikSchedule.decode("sweep", %{"every" => "30m", "prompt" => "Look."})
    end

    test "reads a registered source from the fields left" do
      Application.put_env(:wardrik_schedule, :wardrik_schedule_sources, watch: Watch)
      on_exit(fn -> Application.delete_env(:wardrik_schedule, :wardrik_schedule_sources) end)

      fields = %{"every" => "1h", "prompt" => "What is new?", "watch" => "mentions"}

      assert {:ok, %WardrikSchedule{source: {Watch, "mentions"}} = schedule} =
               WardrikSchedule.decode("mentions", fields)

      assert %{"watch" => "mentions", "every" => "1h"} = WardrikSchedule.encode(schedule)
      assert "watch" in WardrikSchedule.keys()

      assert WardrikSchedule.decode("mentions", Map.put(fields, "watch", 1)) ==
               {:error, "watch names the answers a test hands it"}

      assert {:error,
              "when is not a setting; expected every, prompt, overlap, missed, jitter or watch"} =
               WardrikSchedule.decode("mentions", %{"every" => "1h", "when" => "now"})
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
        assert WardrikSchedule.decode("sweep", fields) == {:error, message}
      end
    end
  end

  describe "firing" do
    test "asks the agent, and says so on its topic", %{key: key} do
      spawn_agent(key, {AgentRunners, :echo, [self(), "done"]})

      {:ok, _pid} = WardrikSchedule.put(key, "tick", every: @every, prompt: "Check the queue.")

      assert_receive {:turn, [user: "Check the queue."]}
      assert_receive %Event{payload: %Event.ScheduleFired{name: "tick", outcome: :asked}}
    end

    test "leaves a running agent be when it skips overlaps", %{key: key} do
      spawn_agent(key, {AgentRunners, :blocking, [self(), "done"]})

      {:ok, _pid} = WardrikSchedule.put(key, "tick", every: @every, prompt: "Check the queue.")

      assert_receive {:turn, _context, turn}
      assert_receive %Event{payload: %Event.ScheduleFired{name: "tick", outcome: :asked}}
      assert_receive %Event{payload: %Event.ScheduleFired{name: "tick", outcome: :busy}}
      send(turn, :release)
    end

    test "asks a running agent anyway when it queues overlaps", %{key: key} do
      spawn_agent(key, {AgentRunners, :blocking, [self(), "done"]})

      {:ok, _pid} =
        WardrikSchedule.put(key, "tick",
          every: @every,
          prompt: "Check the queue.",
          overlap: :queue
        )

      assert_receive {:turn, _context, turn}
      assert_receive %Event{payload: %Event.ScheduleFired{name: "tick", outcome: :asked}}
      assert_receive %Event{payload: %Event.ScheduleFired{name: "tick", outcome: :asked}}
      send(turn, :release)
    end

    test "says there is no agent to ask when none runs under the key", %{key: key} do
      :ok = Event.Bus.subscribe(key, level: :lifecycle)

      {:ok, _pid} = WardrikSchedule.put(key, "tick", every: @every, prompt: "Check the queue.")

      assert_receive %Event{payload: %Event.ScheduleFired{name: "tick", outcome: :no_agent}}
    end
  end

  describe "firing with a source" do
    setup [:watching]

    setup %{key: key} do
      name = :"watch_#{System.unique_integer([:positive])}"
      %{key: key, name: name}
    end

    test "asks with what it found under the prompt, labelled as its items are",
         %{key: key, name: name} do
      item = %Item{
        id: "1",
        title: "Acme on the front page",
        link: "https://example.com/1",
        labels: ["outside"]
      }

      {:ok, _pid} = Watch.answers(name, [fn nil -> {:ok, [item], "1"} end])
      spawn_agent(key, {__MODULE__, :labelled, [self()]})

      {:ok, _pid} =
        WardrikSchedule.put(key, "mentions",
          every: @every,
          prompt: "What is new?",
          source: {Watch, Atom.to_string(name)}
        )

      assert_receive {:asked, text, ["outside"]}
      assert text == "What is new?\n\n## Acme on the front page\nhttps://example.com/1"
      assert_receive %Event{payload: %Event.ScheduleFired{name: "mentions", outcome: :asked}}

      assert_receive %Event{
        payload: %Event.ScheduleFired{name: "mentions", outcome: :nothing_new}
      }

      refute_received {:asked, _text, _labels}
    end

    test "keeps the cursor only once the agent is asked", %{key: key, name: name} do
      test = self()
      found = fn cursor -> send(test, {:checked, cursor}) && {:ok, [%Item{id: "1"}], "1"} end
      {:ok, _pid} = Watch.answers(name, [found, found])
      spawn_agent(key, {AgentRunners, :blocking, [self(), "done"]})
      {:ok, _pid} = WardrikSchedule.put(key, "busy", every: @every, prompt: "Look.")

      assert_receive {:turn, _context, turn}

      {:ok, _pid} =
        WardrikSchedule.put(key, "mentions",
          every: @every,
          prompt: "What is new?",
          source: {Watch, Atom.to_string(name)}
        )

      assert_receive {:checked, nil}
      assert_receive %Event{payload: %Event.ScheduleFired{name: "mentions", outcome: :busy}}
      assert_receive {:checked, nil}
      send(turn, :release)
    end

    test "fails a run its source could not check", %{key: key, name: name} do
      {:ok, _pid} = Watch.answers(name, [fn _cursor -> {:error, "the feed did not answer"} end])
      :ok = Event.Bus.subscribe(key, level: :lifecycle)

      {:ok, _pid} =
        WardrikSchedule.put(key, "mentions",
          every: @every,
          prompt: "What is new?",
          source: {Watch, Atom.to_string(name)}
        )

      assert_receive %Event{payload: %Event.ScheduleFired{name: "mentions", outcome: :failed}}
    end
  end

  describe "list/1 and sync/2" do
    test "lists an agent's schedules with their next run", %{key: key} do
      {:ok, _pid} = WardrikSchedule.put(key, "sweep", every: "@daily", prompt: "Look.")

      assert [
               %WardrikSchedule.Status{name: "sweep", agent: ^key, every: {:cron, "@daily"}} =
                 status
             ] =
               WardrikSchedule.for_agent(key)

      assert DateTime.compare(status.next_at, DateTime.utc_now()) == :gt
    end

    test "finds an agent's schedules and none of its conversations'", %{key: key} do
      conversation = Wardrik.AgentID.put_external_id(key, "thread-1")
      on_exit(fn -> :ok = WardrikSchedule.sync(conversation, []) end)

      {:ok, _pid} = WardrikSchedule.put(key, "b", every: "@daily", prompt: "Look.")
      {:ok, _pid} = WardrikSchedule.put(key, "a", every: "@daily", prompt: "Look.")
      {:ok, _pid} = WardrikSchedule.put(conversation, "c", every: "@daily", prompt: "Look.")

      assert [%{name: "a"}, %{name: "b"}] = WardrikSchedule.for_agent(key)
      assert [%{name: "c", agent: ^conversation}] = WardrikSchedule.for_agent(conversation)

      :ok = WardrikSchedule.delete(key, "a")
      assert [%{name: "b"}] = WardrikSchedule.for_agent(key)
    end

    test "puts the schedules it is given and deletes the rest", %{key: key} do
      {:ok, _pid} = WardrikSchedule.put(key, "old", every: "@daily", prompt: "Look.")
      daily = WardrikSchedule.new("new", every: "@daily", prompt: "Look.")

      assert :ok = WardrikSchedule.sync(key, [daily])
      assert [%{name: "new"}] = WardrikSchedule.for_agent(key)
    end
  end
end
