defmodule Wardrik.Agent.MessageTest do
  use ExUnit.Case, async: true

  alias Wardrik.Agent.Message
  alias Wardrik.Principal

  test "is read as its text alone where nobody is named as sending it" do
    assert Message.content(Message.new("What changed?")) == "What changed?"
  end

  test "is read after a line naming who sent it, by name where they have one" do
    maria = Principal.new(:channel, "slack/U024BE7LH", name: "Maria Chen")
    nameless = Principal.new(:channel, "slack/U024BE7LH")

    assert Message.content(Message.new("What changed?", nil, sender: maria)) ==
             "From Maria Chen (channel slack/U024BE7LH):\nWhat changed?"

    assert Message.content(Message.new("What changed?", nil, sender: nameless)) ==
             "From channel slack/U024BE7LH:\nWhat changed?"
  end

  test "takes a principal as its sender, and nothing else" do
    assert_raise FunctionClauseError, fn -> Message.new("Hi.", nil, sender: "maria") end
  end
end
