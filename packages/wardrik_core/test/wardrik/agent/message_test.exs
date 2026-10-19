defmodule Wardrik.Agent.MessageTest do
  use ExUnit.Case, async: true

  alias Wardrik.Agent.Message
  alias Wardrik.Principal

  test "is read as its text alone where nobody is named as sending it" do
    assert Message.content(Message.new("What changed?")) == "What changed?"
  end

  test "is read after a line naming who sent it, by name where they have one" do
    maria = Principal.new("slack:U024BE7LH", name: "Maria Chen")
    nameless = Principal.new("slack:U024BE7LH")

    assert Message.content(Message.new("What changed?", nil, sender: maria)) ==
             "From Maria Chen (slack:U024BE7LH):\nWhat changed?"

    assert Message.content(Message.new("What changed?", nil, sender: nameless)) ==
             "From slack:U024BE7LH:\nWhat changed?"
  end

  test "is read from its text parts, or its content, with the id its sender chose" do
    parts = [%{"type" => "text", "content" => "a"}, %{"type" => "text", "content" => "b"}]

    assert Message.read(%{"id" => "m1", "parts" => parts}) == {:ok, "a\nb", "m1"}
    assert Message.read(%{"content" => "hi"}) == {:ok, "hi", nil}

    for message <- [%{}, %{"content" => 7}, %{"content" => "hi", "id" => 7}] do
      assert {:error, %Wardrik.Error{type: :invalid}} = Message.read(message)
    end
  end

  test "takes a principal as its sender, and nothing else" do
    assert_raise FunctionClauseError, fn -> Message.new("Hi.", nil, sender: "maria") end
  end
end
