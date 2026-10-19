defmodule Wardrik.LLM.TokensTest do
  use ExUnit.Case, async: true

  alias Wardrik.Conversation
  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.Conversation.User
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Tokens

  defp chars(label, n), do: String.duplicate(label, n)

  test "text is four characters to a token" do
    assert Tokens.text(chars("a", 400)) == 100
    assert Tokens.text("") == 0
  end

  test "messages count their text and their tool calls" do
    call = %ToolCall{id: "call_1", name: "lookup", arguments: %{}}
    asked = [User.new(chars("q", 400))]

    assert Tokens.messages(asked) == 100
    assert Tokens.messages(asked ++ [%Assistant{parts: [call]}]) > 100
  end

  test "every tail counts as messages/1 counts it, rounding the whole tail" do
    call = %ToolCall{id: "call_1", name: "lookup", arguments: %{}}

    messages = [
      User.new(chars("q", 3)),
      %Assistant{parts: [call]},
      User.new(chars("r", 3)),
      Assistant.new(chars("a", 3))
    ]

    assert Tokens.tails(messages) ==
             for(n <- 0..3, do: Tokens.messages(Enum.drop(messages, n)))

    assert Tokens.tails([]) == []
  end

  test "a request counts its messages, its system prompt and its tools" do
    tool =
      Wardrik.Tool.new!(
        name: "lookup",
        description: chars("d", 400),
        schema: [],
        run: fn _args, _context -> {:ok, %{}} end
      )

    context = Conversation.new([User.new(chars("q", 400))])

    offered = Request.new(Config.new(system: chars("s", 400), tools: [tool]), context)

    assert Tokens.request(Request.new(Config.new(), context)) == 100
    assert Tokens.request(offered) > 300
  end
end
