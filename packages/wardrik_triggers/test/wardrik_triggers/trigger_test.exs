defmodule WardrikTriggers.TriggerTest do
  use ExUnit.Case, async: true

  alias WardrikTriggers.Trigger

  test "reads a trigger on a clock, with what it leaves out" do
    assert {:ok,
            %Trigger{
              name: "trigger-2",
              every: "0 9 * * *",
              clock: {:cron, _expression},
              timezone: "Etc/UTC",
              overlap: :settle,
              missed: :run_once,
              jitter: 0,
              feeds: []
            } = trigger} = Trigger.decode(%{"every" => "0 9 * * *", "prompt" => "Go."}, 2)

    assert Trigger.encode(trigger) == %{
             "name" => "trigger-2",
             "every" => "0 9 * * *",
             "prompt" => "Go.",
             "overlap" => "settle",
             "missed" => "run_once"
           }
  end

  test "reads a feed, a webhook, and what each sets" do
    assert {:ok,
            %Trigger{feeds: ["https://a.test/rss"], jitter: 30, timezone: "Europe/Berlin"} = feed} =
             Trigger.decode(%{
               "name" => "rivals",
               "every" => "6h",
               "feed" => "https://a.test/rss",
               "jitter" => 30,
               "timezone" => "Europe/Berlin",
               "prompt" => "What changed?"
             })

    assert %{"feed" => ["https://a.test/rss"], "jitter" => 30, "timezone" => "Europe/Berlin"} =
             Trigger.encode(feed)

    assert {:ok,
            %Trigger{
              clock: nil,
              overlap: :queue,
              webhook: %{secret: "${HOOK}", verify: :standard}
            } = hook} =
             Trigger.decode(%{
               "name" => "issues",
               "webhook" => %{"secret" => "${HOOK}", "verify" => "standard"},
               "prompt" => "Triage it."
             })

    assert %{"webhook" => %{"secret" => "${HOOK}", "verify" => "standard"}} = Trigger.encode(hook)

    assert {:ok, %Trigger{prompt: nil, prompt_file: "HEARTBEAT.md"}} =
             Trigger.decode(%{"every" => "30m", "prompt_file" => "HEARTBEAT.md"})
  end

  test "says what's wrong with a trigger it can't read" do
    base = %{"every" => "1h", "prompt" => "Go."}

    assert {:error, "colour is not a setting of a trigger"} =
             Trigger.decode(Map.put(base, "colour", "blue"))

    assert {:error, "a trigger has every, or a webhook"} = Trigger.decode(%{"prompt" => "Go."})

    assert {:error, "a webhook trigger has no every"} =
             Trigger.decode(Map.put(base, "webhook", %{"secret" => "${S}"}))

    assert {:error, "a webhook names its secret" <> _} =
             Trigger.decode(%{"webhook" => %{"secret" => "plain"}, "prompt" => "Go."})

    assert {:error, "every is a cron" <> _} = Trigger.decode(Map.put(base, "every", 5))

    assert {:error, "\"Mars/Olympus\" is not a time zone"} =
             Trigger.decode(Map.put(base, "timezone", "Mars/Olympus"))

    assert {:error, "a trigger has a prompt" <> _} = Trigger.decode(%{"every" => "1h"})
    assert {:error, "a trigger's name holds" <> _} = Trigger.decode(Map.put(base, "name", "a/b"))
    assert {:error, "a trigger's name is text"} = Trigger.decode(Map.put(base, "name", 7))

    assert {:error, "overlap is one of queue, settle, skip"} =
             Trigger.decode(Map.put(base, "overlap", "maybe"))

    assert {:error, "a feed is a URL" <> _} = Trigger.decode(Map.put(base, "feed", [1]))
    assert {:error, "a feed is a URL" <> _} = Trigger.decode(Map.put(base, "feed", 1))
    assert {:error, "a trigger is a map" <> _} = Trigger.decode("daily")
  end
end
