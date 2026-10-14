defmodule WardrikTriggerTest.Watch do
  @moduledoc false
  @behaviour WardrikTrigger.Source

  # Answers each check with the next of the answers its test hands it, each a
  # function of the cursor, and with nothing new once they run out.

  @impl WardrikTrigger.Source
  def decode(%{"watch" => name} = fields) when map_size(fields) == 1 and is_binary(name),
    do: {:ok, name}

  def decode(_fields), do: {:error, "watch names the answers a test hands it"}

  @impl WardrikTrigger.Source
  def encode(name), do: %{"watch" => name}

  @impl WardrikTrigger.Source
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

defmodule WardrikTriggerTest do
  use ExUnit.Case, async: false

  alias ReqLLM.Context
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.LLM.Turn
  alias Wardrik.Test.AgentRunners
  alias WardrikTrigger.Item
  alias WardrikTriggerTest.Watch

  # Short enough to fire within an assert_receive, long enough that a test
  # sees each firing it waits for.
  @every {:interval, 50}

  setup do
    key = Wardrik.Test.Fleet.id("triggered")

    on_exit(fn ->
      :ok = WardrikTrigger.sync(key, [])
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
    register_watch()
  end

  # Registers the test's source beside those the package registers, and puts
  # them back after.
  defp register_watch do
    sources = Application.get_env(:wardrik_trigger, :wardrik_trigger_sources, [])
    Application.put_env(:wardrik_trigger, :wardrik_trigger_sources, sources ++ [watch: Watch])
    on_exit(fn -> Application.put_env(:wardrik_trigger, :wardrik_trigger_sources, sources) end)
  end

  defp spawn_agent(key, runner) do
    {:ok, _pid} = Fleet.spawn(key, runner: runner)
    :ok = Event.Bus.subscribe(key, level: :lifecycle)
  end

  describe "new/2" do
    test "reads a duration as an interval" do
      assert %WardrikTrigger{every: {:interval, 1_800_000}} =
               WardrikTrigger.new("sweep", every: "30m", prompt: "Look.")

      assert %WardrikTrigger{every: {:interval, 86_400_000}} =
               WardrikTrigger.new("sweep", every: "1d", prompt: "Look.")
    end

    test "keeps a cron expression as the text it read" do
      assert %WardrikTrigger{every: {:cron, "*/30 * * * *"}} =
               WardrikTrigger.new("sweep", every: " */30 * * * * ", prompt: "Look.")
    end

    test "refuses what it cannot read" do
      assert_raise ArgumentError, ~r/shorter than a minute/, fn ->
        WardrikTrigger.new("sweep", every: "30s", prompt: "Look.")
      end

      assert_raise ArgumentError, ~r/every: .*not five fields/, fn ->
        WardrikTrigger.new("sweep", every: "every half hour", prompt: "Look.")
      end

      assert_raise ArgumentError, ~r/prompt is a string/, fn ->
        WardrikTrigger.new("sweep", every: "30m")
      end

      assert_raise ArgumentError, ~r/may not contain "\/"/, fn ->
        WardrikTrigger.new("a/b", every: "30m", prompt: "Look.")
      end

      assert_raise ArgumentError, ~r/overlap is one of :skip, :queue/, fn ->
        WardrikTrigger.new("sweep", every: "30m", prompt: "Look.", overlap: :interrupt)
      end
    end
  end

  describe "encode/1" do
    test "writes a trigger as decode/2 reads it" do
      for fields <- [
            %{
              "every" => "*/30 * * * *",
              "prompt" => "Look.",
              "overlap" => "queue",
              "jitter" => 30
            },
            %{"every" => "90m", "prompt" => "Look.", "missed" => "skip"}
          ] do
        {:ok, trigger} = WardrikTrigger.decode("sweep", fields)
        encoded = WardrikTrigger.encode(trigger)

        assert {:ok, ^trigger} = WardrikTrigger.decode("sweep", Map.delete(encoded, "name"))
        assert encoded["name"] == "sweep"
      end

      assert %{"every" => "2h", "overlap" => "skip", "missed" => "run_once", "jitter" => 0} =
               WardrikTrigger.encode(WardrikTrigger.new("sweep", every: "120m", prompt: "Look."))
    end
  end

  describe "decode/2" do
    test "reads a trigger's fields written as text" do
      assert {:ok,
              %WardrikTrigger{
                name: "sweep",
                every: {:cron, "*/30 * * * *"},
                prompt: "Look.",
                overlap: :queue,
                missed: :skip,
                jitter: 30_000
              }} =
               WardrikTrigger.decode("sweep", %{
                 "every" => "*/30 * * * *",
                 "prompt" => "Look.",
                 "overlap" => "queue",
                 "missed" => "skip",
                 "jitter" => 30
               })

      assert {:ok, %WardrikTrigger{every: {:interval, 1_800_000}, overlap: :skip, jitter: 0}} =
               WardrikTrigger.decode("sweep", %{"every" => "30m", "prompt" => "Look."})
    end

    test "reads a registered source from the fields left" do
      register_watch()

      fields = %{"every" => "1h", "prompt" => "What is new?", "watch" => "mentions"}

      assert {:ok, %WardrikTrigger{source: {Watch, "mentions"}} = trigger} =
               WardrikTrigger.decode("mentions", fields)

      assert %{"watch" => "mentions", "every" => "1h"} = WardrikTrigger.encode(trigger)
      assert "watch" in WardrikTrigger.keys()

      assert WardrikTrigger.decode("mentions", Map.put(fields, "watch", 1)) ==
               {:error, "watch names the answers a test hands it"}

      assert {:error,
              "when is not a setting; expected every, prompt, overlap, missed, jitter, feed, watch or webhook"} =
               WardrikTrigger.decode("mentions", %{"every" => "1h", "when" => "now"})
    end

    test "reads a webhook trigger as a kind of its own" do
      fields = %{"webhook" => %{"secret" => "${HOOK_SECRET}"}, "prompt" => "Look."}

      assert {:ok, %WardrikTrigger.Webhook{verify: "shared", overlap: :queue} = hook} =
               WardrikTrigger.decode("issues", fields)

      assert {:ok, ^hook} =
               WardrikTrigger.decode("issues", Map.delete(WardrikTrigger.encode(hook), "name"))

      assert "webhook" in WardrikTrigger.keys()
    end

    test "says what does not read" do
      for {fields, message} <- [
            {%{"when" => "now"},
             "when is not a setting; expected every, prompt, overlap, missed, jitter, feed or webhook"},
            {%{"prompt" => "Look."}, ~s(every is a cron expression, or a duration such as "30m")},
            {%{"every" => "30m", "prompt" => "Look.", "overlap" => "interrupt"},
             "overlap is one of skip, queue"},
            {%{"every" => "30m", "prompt" => "Look.", "missed" => 1},
             "missed is one of run_once, skip"},
            {%{"every" => "30m", "prompt" => "Look.", "jitter" => 1.5},
             "jitter is a whole number of seconds"},
            {%{"every" => "30s", "prompt" => "Look."}, ~s(every: "30s" is shorter than a minute)}
          ] do
        assert WardrikTrigger.decode("sweep", fields) == {:error, message}
      end
    end
  end

  describe "firing" do
    test "asks the agent, and says so on its topic", %{key: key} do
      spawn_agent(key, {AgentRunners, :echo, [self(), "done"]})

      {:ok, _pid} = WardrikTrigger.put(key, "tick", every: @every, prompt: "Check the queue.")

      assert_receive {:turn, [user: "Check the queue."]}
      assert_receive %Event{payload: %Event.TriggerFired{name: "tick", outcome: :asked}}
    end

    test "leaves a running agent be when it skips overlaps", %{key: key} do
      spawn_agent(key, {AgentRunners, :blocking, [self(), "done"]})

      {:ok, _pid} = WardrikTrigger.put(key, "tick", every: @every, prompt: "Check the queue.")

      assert_receive {:turn, _context, turn}
      assert_receive %Event{payload: %Event.TriggerFired{name: "tick", outcome: :asked}}
      assert_receive %Event{payload: %Event.TriggerFired{name: "tick", outcome: :busy}}
      send(turn, :release)
    end

    test "asks a running agent anyway when it queues overlaps", %{key: key} do
      spawn_agent(key, {AgentRunners, :blocking, [self(), "done"]})

      {:ok, _pid} =
        WardrikTrigger.put(key, "tick",
          every: @every,
          prompt: "Check the queue.",
          overlap: :queue
        )

      assert_receive {:turn, _context, turn}
      assert_receive %Event{payload: %Event.TriggerFired{name: "tick", outcome: :asked}}
      assert_receive %Event{payload: %Event.TriggerFired{name: "tick", outcome: :asked}}
      send(turn, :release)
    end

    test "says there is no agent to ask when none runs under the key", %{key: key} do
      :ok = Event.Bus.subscribe(key, level: :lifecycle)

      {:ok, _pid} = WardrikTrigger.put(key, "tick", every: @every, prompt: "Check the queue.")

      assert_receive %Event{payload: %Event.TriggerFired{name: "tick", outcome: :no_agent}}
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
        WardrikTrigger.put(key, "mentions",
          every: @every,
          prompt: "What is new?",
          source: {Watch, Atom.to_string(name)}
        )

      assert_receive {:asked, text, ["outside"]}
      assert text == "What is new?\n\n## Acme on the front page\nhttps://example.com/1"
      assert_receive %Event{payload: %Event.TriggerFired{name: "mentions", outcome: :asked}}

      assert_receive %Event{
        payload: %Event.TriggerFired{name: "mentions", outcome: :nothing_new}
      }

      refute_received {:asked, _text, _labels}
    end

    test "keeps the cursor only once the agent is asked", %{key: key, name: name} do
      test = self()
      found = fn cursor -> send(test, {:checked, cursor}) && {:ok, [%Item{id: "1"}], "1"} end
      {:ok, _pid} = Watch.answers(name, [found, found])
      spawn_agent(key, {AgentRunners, :blocking, [self(), "done"]})
      {:ok, _pid} = WardrikTrigger.put(key, "busy", every: @every, prompt: "Look.")

      assert_receive {:turn, _context, turn}

      {:ok, _pid} =
        WardrikTrigger.put(key, "mentions",
          every: @every,
          prompt: "What is new?",
          source: {Watch, Atom.to_string(name)}
        )

      assert_receive {:checked, nil}
      assert_receive %Event{payload: %Event.TriggerFired{name: "mentions", outcome: :busy}}
      assert_receive {:checked, nil}
      send(turn, :release)
    end

    test "fails a run its source could not check", %{key: key, name: name} do
      {:ok, _pid} = Watch.answers(name, [fn _cursor -> {:error, "the feed did not answer"} end])
      :ok = Event.Bus.subscribe(key, level: :lifecycle)

      {:ok, _pid} =
        WardrikTrigger.put(key, "mentions",
          every: @every,
          prompt: "What is new?",
          source: {Watch, Atom.to_string(name)}
        )

      assert_receive %Event{payload: %Event.TriggerFired{name: "mentions", outcome: :failed}}
    end
  end

  # Secrets are read for the agent a trigger asks, as a daemon's vault keeps
  # one for each org, and from the environment past that.
  defp deliver(key, name, request) do
    secrets = fn
      "WARDRIK_TEST_VAULTED", %Wardrik.AgentID{org: "acme"} -> "acme's"
      "WARDRIK_TEST_VAULTED", %Wardrik.AgentID{org: "globex"} -> "globex's"
      name, _agent -> System.get_env(name)
    end

    Wardrik.Triggers.deliver(%WardrikTrigger.Deliveries{secrets: secrets}, key, name,
      request: request
    )
  end

  describe "deliver/4" do
    setup %{key: key} do
      System.put_env("WARDRIK_TEST_HOOK", "s3cret")
      on_exit(fn -> System.delete_env("WARDRIK_TEST_HOOK") end)

      put = fn opts ->
        hook =
          WardrikTrigger.Webhook.new(
            "issues",
            [prompt: "An event is below.", secret: "WARDRIK_TEST_HOOK"] ++ opts
          )

        WardrikTrigger.put(key, hook)
      end

      %{put: put}
    end

    defp request(id, body, secret \\ "s3cret") do
      %{
        headers: [{"authorization", "Bearer " <> secret}, {"idempotency-key", id}],
        body: body
      }
    end

    test "asks the agent about a request once, however often it is sent",
         %{key: key, put: put} do
      spawn_agent(key, {__MODULE__, :labelled, [self()]})
      {:ok, _pid} = put.([])

      assert [
               %WardrikTrigger.Status{
                 name: "issues",
                 schedule: "on request",
                 next: [],
                 paths: [path]
               }
             ] = WardrikTrigger.for_agent(key)

      assert path == "/v1/hooks/#{key}/issues"

      request = request("d-1", ~s({"action":"opened"}))
      assert deliver(key, "issues", request) == {:ok, :asked}

      assert_receive {:asked, text, ["outside"]}
      assert text =~ ~r/\AAn event is below.\n\n## \S+\n\{"action":"opened"\}\z/
      assert_receive %Event{payload: %Event.TriggerFired{name: "issues", outcome: :asked}}

      assert deliver(key, "issues", request) == {:ok, :seen}
      refute_receive {:asked, _text, _labels}, 100
    end

    test "refuses a request its secret did not sign", %{key: key, put: put} do
      spawn_agent(key, {__MODULE__, :labelled, [self()]})
      {:ok, _pid} = put.([])

      assert {:error, :forbidden, "The request's secret is not the trigger's."} =
               deliver(key, "issues", request("d-1", "{}", "guess"))

      refute_received {:asked, _text, _labels}
    end

    test "keeps no request it could not deliver, so the next try delivers it",
         %{key: key, put: put} do
      spawn_agent(key, {AgentRunners, :blocking, [self(), "done"]})
      {:ok, _pid} = put.(overlap: :skip)
      {:ok, _pid} = WardrikTrigger.put(key, "busy", every: @every, prompt: "Look.")
      assert_receive {:turn, _context, turn}
      :ok = WardrikTrigger.delete(key, "busy")

      assert {:error, :unavailable, "The agent is busy" <> _rest} =
               deliver(key, "issues", request("d-1", "{}"))

      assert_receive %Event{payload: %Event.TriggerFired{name: "issues", outcome: :busy}}

      {:ok, _pid} = put.(overlap: :queue)
      assert deliver(key, "issues", request("d-1", "{}")) == {:ok, :asked}
      send(turn, :release)
    end

    test "says the agent has no such trigger to deliver to", %{key: key} do
      assert deliver(key, "issues", request("d-1", "{}")) == {:error, :not_found}

      {:ok, _pid} = WardrikTrigger.put(key, "issues", every: "@daily", prompt: "Look.")
      assert deliver(key, "issues", request("d-1", "{}")) == {:error, :not_found}
    end

    test "becomes the other kind when put under the same name", %{key: key, put: put} do
      {:ok, _pid} = WardrikTrigger.put(key, "issues", every: "@daily", prompt: "Look.")
      {:ok, _pid} = put.([])
      spawn_agent(key, {__MODULE__, :labelled, [self()]})

      assert [%WardrikTrigger.Status{schedule: "on request"}] = WardrikTrigger.for_agent(key)
      assert deliver(key, "issues", request("d-1", "{}")) == {:ok, :asked}

      {:ok, _pid} = WardrikTrigger.put(key, "issues", every: "@daily", prompt: "Look.")
      assert [%WardrikTrigger.Status{schedule: "@daily"}] = WardrikTrigger.for_agent(key)
    end
  end

  describe "list/1 and sync/2" do
    test "lists an agent's triggers with their next run", %{key: key} do
      {:ok, _pid} = WardrikTrigger.put(key, "sweep", every: "@daily", prompt: "Look.")

      assert [
               %WardrikTrigger.Status{name: "sweep", agent: ^key, schedule: "@daily"} =
                 status
             ] =
               WardrikTrigger.for_agent(key)

      assert [next] = status.next
      assert DateTime.compare(next, DateTime.utc_now()) == :gt
    end

    test "finds an agent's triggers and none of its conversations'", %{key: key} do
      conversation = Wardrik.AgentID.put_external_id(key, "thread-1")
      on_exit(fn -> :ok = WardrikTrigger.sync(conversation, []) end)

      {:ok, _pid} = WardrikTrigger.put(key, "b", every: "@daily", prompt: "Look.")
      {:ok, _pid} = WardrikTrigger.put(key, "a", every: "@daily", prompt: "Look.")
      {:ok, _pid} = WardrikTrigger.put(conversation, "c", every: "@daily", prompt: "Look.")

      assert [%{name: "a"}, %{name: "b"}] = WardrikTrigger.for_agent(key)
      assert [%{name: "c", agent: ^conversation}] = WardrikTrigger.for_agent(conversation)

      :ok = WardrikTrigger.delete(key, "a")
      assert [%{name: "b"}] = WardrikTrigger.for_agent(key)
    end

    test "puts the triggers it is given and deletes the rest", %{key: key} do
      {:ok, _pid} = WardrikTrigger.put(key, "old", every: "@daily", prompt: "Look.")
      daily = WardrikTrigger.new("new", every: "@daily", prompt: "Look.")

      assert :ok = WardrikTrigger.sync(key, [daily])
      assert [%{name: "new"}] = WardrikTrigger.for_agent(key)
    end
  end
end
