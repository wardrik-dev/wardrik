defmodule Wardrik.LLM.TokensTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Tokens

  defp chars(label, n), do: String.duplicate(label, n)

  test "text is four characters to a token" do
    assert Tokens.text(chars("a", 400)) == 100
    assert Tokens.text("") == 0
  end

  test "messages count their text and their tool calls" do
    call = ReqLLM.ToolCall.new("call_1", "lookup", "{}")
    asked = [Context.user(chars("q", 400))]

    assert Tokens.messages(asked) == 100
    assert Tokens.messages(asked ++ [Context.assistant("", tool_calls: [call])]) > 100
  end

  test "every tail counts as messages/1 counts it, rounding the whole tail" do
    call = ReqLLM.ToolCall.new("call_1", "lookup", "{}")

    messages = [
      Context.user(chars("q", 3)),
      Context.assistant("", tool_calls: [call]),
      Context.user(chars("r", 3)),
      Context.assistant(chars("a", 3))
    ]

    assert Tokens.tails(messages) ==
             for(n <- 0..3, do: Tokens.messages(Enum.drop(messages, n)))

    assert Tokens.tails([]) == []
  end

  test "a request counts its messages, its system prompt and its tools" do
    tool =
      ReqLLM.Tool.new!(
        name: "lookup",
        description: chars("d", 400),
        parameter_schema: [],
        callback: fn _args -> {:ok, %{}} end
      )

    context = Context.new([Context.user(chars("q", 400))])

    offered = Request.new(Config.new(system: chars("s", 400), tools: [tool]), context)

    assert Tokens.request(Request.new(Config.new(), context)) == 100
    assert Tokens.request(offered) > 300
  end
end
