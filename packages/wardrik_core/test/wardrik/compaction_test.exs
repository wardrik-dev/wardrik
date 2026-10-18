defmodule Wardrik.CompactionTest do
  use ExUnit.Case, async: true
  use Mimic

  alias ReqLLM.Context
  alias Wardrik.Compaction
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Tokens
  alias Wardrik.Run
  alias Wardrik.Test.LLMStub

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

  defp text(%{content: content}) when is_binary(content), do: content
  defp text(%{content: parts}), do: Enum.map_join(parts, "", &(&1.text || ""))

  defp small, do: Compaction.new(window: 500, at: 0.6, keep: 0.5)

  # A window the older part of `history/0` fits half of.
  defp roomy, do: Compaction.new(window: 1_000, at: 0.3, keep: 0.25)

  describe "new/1" do
    test "takes shares of the window, keeping less than it waits for" do
      assert %Compaction{at: 0.5, keep: 0.2} = Compaction.new(at: 0.5, keep: 0.2)

      assert_raise ArgumentError, ~r/keeps less than it waits for/, fn ->
        Compaction.new(at: 0.5, keep: 0.5)
      end

      assert_raise ArgumentError, ~r/:at is a share/, fn -> Compaction.new(at: 1.5) end

      assert_raise ArgumentError, ~r/:window is a whole number/, fn ->
        Compaction.new(window: 0)
      end
    end
  end

  describe "split/3" do
    test "keeps a history that has not outgrown its window" do
      assert Compaction.split(Compaction.new(window: 1_000_000), history(), "any:model") == :keep
      assert Compaction.split(nil, history(), "any:model") == :keep
    end

    test "cuts an outgrown history where a person's message begins, keeping a tool call with its result" do
      assert {:ok, older, recent} = Compaction.split(small(), history(), "any:model")

      assert [%{role: :user} | _] = recent
      assert [_, _, _, _] = older
      assert Enum.map(older, & &1.role) == [:user, :assistant, :tool, :assistant]
      assert Tokens.messages(recent) <= 0.5 * 500
    end

    test "keeps the longest tail that fits, where more than one would" do
      long =
        Context.new([
          Context.user(String.duplicate("x", 4_000)),
          Context.assistant(String.duplicate("a", 200)),
          Context.user(String.duplicate("q", 200)),
          Context.assistant(String.duplicate("a", 200)),
          Context.user(String.duplicate("q", 200)),
          Context.assistant(String.duplicate("a", 200))
        ])

      assert {:ok, [_q1, _a1], [%{role: :user}, _a2, _q3, _a3]} =
               Compaction.split(small(), long, "any:model")
    end

    test "keeps at least the last question, however long it is" do
      long =
        Context.new([
          Context.user(words("q1")),
          Context.assistant(words("a1")),
          Context.user(String.duplicate("x", 4_000))
        ])

      assert {:ok, [_q1, _a1], [%{role: :user}]} = Compaction.split(small(), long, "any:model")
    end

    test "leaves a history with nowhere to cut as it is" do
      one = Context.new([Context.user(String.duplicate("x", 4_000)), Context.assistant("ok")])
      assert Compaction.split(small(), one, "any:model") == :keep
    end

    test "reads a model's window from the catalog, with a default for one it does not know" do
      assert Compaction.window(Compaction.new(), "anthropic:claude-sonnet-5") == 1_000_000
      assert Compaction.window(Compaction.new(), "nowhere:unknown") == 128_000
    end
  end

  describe "prepare/3" do
    defp run, do: Run.root(Config.new(), Wardrik.Test.Fleet.id(), name: "compaction")

    test "replaces the older part with the model's summary, and keeps the recent part word for word" do
      test_pid = self()

      stub(ReqLLM, :generate_text, fn _model, context, opts ->
        send(test_pid, {:asked, context, opts})
        {:ok, LLMStub.final_answer("They asked about lookups; the answer was found.")}
      end)

      assert {:ok, compacted, stats} =
               Wardrik.History.prepare({Compaction, roomy()}, history(), run())

      assert [summary, acknowledgement, second_question, second_answer] =
               Context.to_list(compacted)

      assert summary.role == :user
      assert text(summary) =~ "They asked about lookups"
      assert acknowledgement.role == :assistant
      assert text(second_question) =~ "second question"
      assert text(second_answer) =~ "second answer"

      assert stats.messages_before == 6 and stats.messages_after == 4
      assert stats.tokens_after < stats.tokens_before

      assert_received {:asked, asked, opts}
      assert opts[:tools] in [nil, []]
      assert opts[:system_prompt] =~ "condensing the earlier part"
      assert [_, _, _, _, _] = Context.to_list(asked)
    end

    test "summarises an older part longer than half the window in parts, each within it" do
      test_pid = self()
      {:ok, asked} = Agent.start_link(fn -> 0 end)

      stub(ReqLLM, :generate_text, fn _model, context, _opts ->
        n = Agent.get_and_update(asked, &{&1 + 1, &1 + 1})
        send(test_pid, {:asked, n, Context.to_list(context)})
        {:ok, LLMStub.final_answer("summary #{n}")}
      end)

      assert {:ok, compacted} = Compaction.prepare(history(), run(), small())

      assert_received {:asked, 1, [first]}
      assert_received {:asked, 2, [second]}
      refute_received {:asked, 3, _messages}

      assert text(first) =~ "Person: first question"
      assert text(first) =~ "You called lookup with {}"
      assert text(second) =~ "summary 1"
      assert text(second) =~ "You: first answer"
      assert Tokens.messages([first]) <= 0.6 * 500 and Tokens.messages([second]) <= 0.6 * 500

      assert [summary, _acknowledgement, _question, _answer] = Context.to_list(compacted)
      assert text(summary) =~ "summary 2"
    end

    test "leaves a history whose older part is only an earlier summary as it is" do
      stub(ReqLLM, :generate_text, fn _model, _context, _opts ->
        {:ok, LLMStub.final_answer("They asked about lookups.")}
      end)

      {:ok, compacted} = Compaction.prepare(history(), run(), roomy())
      [summary, acknowledgement | _recent] = Context.to_list(compacted)

      outgrown =
        Context.new([summary, acknowledgement, Context.user(String.duplicate("x", 4_000))])

      assert Compaction.split(small(), outgrown, "any:model") == :keep
    end

    test "is nothing to do for a history that has not outgrown its window" do
      reject(&ReqLLM.generate_text/3)
      assert :keep = Compaction.prepare(history(), run(), Compaction.new())
    end

    test "leaves the history as it was when the summary cannot be made" do
      stub(ReqLLM, :generate_text, fn _model, _context, _opts ->
        {:ok, LLMStub.final_answer("   ")}
      end)

      assert {:error, :empty_summary} = Compaction.prepare(history(), run(), roomy())

      stub(ReqLLM, :generate_text, fn _model, _context, _opts -> {:error, :timeout} end)
      assert {:error, :timeout} = Compaction.prepare(history(), run(), roomy())
    end
  end
end
