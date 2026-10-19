defmodule Wardrik.HistoryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.User
  alias Wardrik.History
  alias Wardrik.LLM.Config
  alias Wardrik.Run

  # A history that answers whatever it was named with.
  defmodule Answering do
    @behaviour Wardrik.History

    @impl true
    def prepare(_history, _run, :raise), do: raise("the store is down")
    def prepare(_history, _run, answer), do: answer
  end

  defp run, do: Run.root(Config.new(), Wardrik.Test.Fleet.id(), name: "turn")

  defp history,
    do: Conversation.new([User.new("first"), Assistant.new("answer"), User.new("second")])

  test "keeps what a history answers, with what changed" do
    kept = Conversation.new([User.new("second")])

    assert {:ok, ^kept, stats} = History.prepare({Answering, {:ok, kept}}, history(), run())
    assert %{messages_before: 3, messages_after: 1} = stats
    assert stats.tokens_after < stats.tokens_before
  end

  test "keeps every message with no history, or one that keeps them" do
    assert History.prepare(nil, history(), run()) == :keep
    assert History.prepare({Answering, :keep}, history(), run()) == :keep
  end

  test "keeps the history as it was, and says so, where one fails, raises or answers otherwise" do
    for value <- [{:error, :timeout}, :raise, :perhaps] do
      log =
        capture_log(fn ->
          assert History.prepare({Answering, value}, history(), run()) == :keep
        end)

      assert log =~ "Wardrik.HistoryTest.Answering kept the history as it was"
    end
  end
end
