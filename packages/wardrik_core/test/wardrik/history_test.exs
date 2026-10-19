defmodule Wardrik.HistoryTest do
  use ExUnit.Case, async: true

  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.User
  alias Wardrik.History
  alias Wardrik.LLM.Config
  alias Wardrik.Run

  defp run, do: Run.root(Config.new(), Wardrik.Test.Fleet.id(), name: "turn")

  test "all keeps every message" do
    history = Conversation.new([User.new("first"), Assistant.new("answer"), User.new("second")])

    assert History.prepare(%History.All{}, history, run: run()) == :keep
  end
end
