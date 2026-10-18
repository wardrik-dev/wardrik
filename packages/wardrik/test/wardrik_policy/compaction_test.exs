defmodule WardrikPolicy.CompactionTest do
  use ExUnit.Case, async: true
  use Mimic

  alias ReqLLM.Context
  alias Wardrik.Compaction
  alias Wardrik.LLM.Config
  alias Wardrik.Scope

  setup :verify_on_exit!

  # 400 characters, about 100 tokens.
  defp words(label), do: String.pad_trailing(label, 400, ".")

  defp history do
    call = ReqLLM.ToolCall.new("call_1", "lookup", "{}")

    Context.new([
      Context.user(words("first question")),
      Context.assistant("", tool_calls: [call]),
      Context.tool_result_message("lookup", "call_1", %{"found" => words("a long result")}),
      Context.assistant(words("first answer")),
      Context.user(words("second question")),
      Context.assistant(words("second answer"))
    ])
  end

  defp scope(opts),
    do: Scope.root(Config.new(), Wardrik.Test.Fleet.id(), [name: "compaction"] ++ opts)

  defp compaction, do: Compaction.new(window: 1_000, at: 0.3, keep: 0.25)

  test "a summary goes through the dispatch, so a budget that has run out stops it" do
    reject(&ReqLLM.generate_text/3)
    policy = WardrikPolicy.decode!(%{"budget" => %{"tokens" => 1}})
    scope = scope(hooks: WardrikPolicy.hooks(policy))

    :ok =
      WardrikPolicy.Meter.spend(
        WardrikPolicy.Spend.key(
          scope.source.agent_id,
          "policy/budget",
          WardrikPolicy.Budget.window(policy.budget, "", DateTime.utc_now())
        ),
        0,
        10
      )

    assert {:error, {:parked, _prompt}} = Compaction.prepare(history(), scope, compaction())
  end
end
