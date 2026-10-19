defmodule WardrikPolicy.CompactionTest do
  use ExUnit.Case, async: true

  alias Wardrik.Compaction
  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.Text
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.Conversation.ToolResult
  alias Wardrik.Conversation.User
  alias Wardrik.LLM.Config
  alias Wardrik.Run

  # 400 characters, about 100 tokens.
  defp words(label), do: String.pad_trailing(label, 400, ".")

  defp history do
    found = JSON.encode!(%{"found" => words("a long result")})

    Conversation.new([
      User.new(words("first question")),
      %Assistant{parts: [%ToolCall{id: "call_1", name: "lookup", arguments: %{}}]},
      %ToolResult{call_id: "call_1", name: "lookup", parts: [%Text{text: found}]},
      Assistant.new(words("first answer")),
      User.new(words("second question")),
      Assistant.new(words("second answer"))
    ])
  end

  # A run whose model calls a test model answers, with no script, so a call
  # that reached it would fail the test.
  defp run(opts) do
    host = Wardrik.Test.host(llm: Wardrik.Test.LLM.start())
    Run.root(Config.new(), Wardrik.Test.Fleet.id(), [name: "compaction", host: host] ++ opts)
  end

  defp compaction, do: Compaction.new(window: 1_000, at: 0.3, keep: 0.25)

  test "a summary goes through the dispatch, so a budget that has run out stops it" do
    policy = WardrikPolicy.decode!(%{"budget" => %{"tokens" => 1}})
    run = run(hooks: WardrikPolicy.hooks(policy))

    :ok =
      WardrikPolicy.Meter.spend(
        WardrikPolicy.Spend.key(
          run.source.agent_id,
          "policy/budget",
          WardrikPolicy.Budget.window(policy.budget, "", DateTime.utc_now())
        ),
        0,
        10
      )

    assert {:error, {:parked, _prompt}} = Compaction.prepare(compaction(), history(), run: run)
  end
end
