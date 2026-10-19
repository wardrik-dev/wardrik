defmodule Wardrik.CompactionTest do
  use ExUnit.Case, async: true

  alias Wardrik.Compaction
  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.Text
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.Conversation.ToolResult
  alias Wardrik.Conversation.User
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Error
  alias Wardrik.LLM.Tokens
  alias Wardrik.Run
  alias Wardrik.Test.LLM

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

  defp small, do: Compaction.new(window: 500, at: 0.6, keep: 0.5)

  # A window the older part of `history/0` fits half of.
  defp roomy, do: Compaction.new(window: 1_000, at: 0.3, keep: 0.25)

  defp run(llm \\ LLM.start()),
    do:
      Run.root(Config.new(), Wardrik.Test.Fleet.id(),
        name: "compaction",
        host: Wardrik.Test.host(llm: llm)
      )

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
      assert Compaction.split(Compaction.new(window: 1_000_000), history(), run()) == :keep
    end

    test "cuts an outgrown history where a person's message begins, keeping a tool call with its result" do
      assert {:ok, older, recent} = Compaction.split(small(), history(), run())

      assert [%User{} | _] = recent
      assert [%User{}, %Assistant{}, %ToolResult{}, %Assistant{}] = older
      assert Tokens.messages(recent) <= 0.5 * 500
    end

    test "keeps the longest tail that fits, where more than one would" do
      long =
        Conversation.new([
          User.new(String.duplicate("x", 4_000)),
          Assistant.new(String.duplicate("a", 200)),
          User.new(String.duplicate("q", 200)),
          Assistant.new(String.duplicate("a", 200)),
          User.new(String.duplicate("q", 200)),
          Assistant.new(String.duplicate("a", 200))
        ])

      assert {:ok, [_q1, _a1], [%User{}, _a2, _q3, _a3]} = Compaction.split(small(), long, run())
    end

    test "keeps at least the last question, however long it is" do
      long =
        Conversation.new([
          User.new(words("q1")),
          Assistant.new(words("a1")),
          User.new(String.duplicate("x", 4_000))
        ])

      assert {:ok, [_q1, _a1], [%User{}]} = Compaction.split(small(), long, run())
    end

    test "leaves a history with nowhere to cut as it is" do
      one = Conversation.new([User.new(String.duplicate("x", 4_000)), Assistant.new("ok")])
      assert Compaction.split(small(), one, run()) == :keep
    end

    test "reads a model's window from the host's client, with a default for one it does not know" do
      known = %LLM{script: nil, window: 1_000_000}

      assert Compaction.window(Compaction.new(), run(known)) == 1_000_000
      assert Compaction.window(Compaction.new(), run(%LLM{script: nil})) == 128_000
    end
  end

  describe "prepare/3" do
    test "replaces the older part with the model's summary, and keeps the recent part word for word" do
      test_pid = self()
      llm = LLM.start()

      LLM.answering(llm, fn asked ->
        send(test_pid, {:asked, asked})
        LLM.final_answer("They asked about lookups; the answer was found.")
      end)

      assert {:ok, compacted} = Wardrik.History.prepare(roomy(), history(), run: run(llm))

      assert [%User{} = summary, %Assistant{}, second_question, second_answer] =
               Conversation.to_list(compacted)

      assert Conversation.text(summary) =~ "They asked about lookups"
      assert Conversation.text(second_question) =~ "second question"
      assert Conversation.text(second_answer) =~ "second answer"

      assert_received {:asked, asked}
      assert asked.tools == []
      assert asked.system =~ "condensing the earlier part"
      assert [_, _, _, _, _] = asked.messages
    end

    test "summarises an older part longer than half the window in parts, each within it" do
      test_pid = self()
      llm = LLM.start()
      {:ok, asked} = Agent.start_link(fn -> 0 end)

      LLM.answering(llm, fn %{messages: messages} ->
        n = Agent.get_and_update(asked, &{&1 + 1, &1 + 1})
        send(test_pid, {:asked, n, messages})
        LLM.final_answer("summary #{n}")
      end)

      assert {:ok, compacted} = Compaction.prepare(small(), history(), run: run(llm))

      assert_received {:asked, 1, [first]}
      assert_received {:asked, 2, [second]}
      refute_received {:asked, 3, _messages}

      assert Conversation.text(first) =~ "Person: first question"
      assert Conversation.text(first) =~ "You called lookup with {}"
      assert Conversation.text(second) =~ "summary 1"
      assert Conversation.text(second) =~ "You: first answer"
      assert Tokens.messages([first]) <= 0.6 * 500 and Tokens.messages([second]) <= 0.6 * 500

      assert [summary, _acknowledgement, _question, _answer] = Conversation.to_list(compacted)
      assert Conversation.text(summary) =~ "summary 2"
    end

    test "leaves a history whose older part is only an earlier summary as it is" do
      llm = LLM.start()
      LLM.stream(llm, [LLM.final_answer("They asked about lookups.")])

      {:ok, compacted} = Compaction.prepare(roomy(), history(), run: run(llm))
      [summary, acknowledgement | _recent] = Conversation.to_list(compacted)

      outgrown =
        Conversation.new([summary, acknowledgement, User.new(String.duplicate("x", 4_000))])

      assert Compaction.split(small(), outgrown, run()) == :keep
    end

    test "is nothing to do for a history that has not outgrown its window" do
      assert :keep = Compaction.prepare(Compaction.new(), history(), run: run())
    end

    test "leaves the history as it was when the summary cannot be made" do
      llm = LLM.start()
      LLM.stream(llm, [LLM.final_answer("   "), %Error{message: "timeout"}])

      assert {:error, :empty_summary} = Compaction.prepare(roomy(), history(), run: run(llm))

      assert {:error, %Error{message: "timeout"}} =
               Compaction.prepare(roomy(), history(), run: run(llm))
    end
  end
end
