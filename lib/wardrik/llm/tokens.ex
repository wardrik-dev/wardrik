defmodule Wardrik.LLM.Tokens do
  @moduledoc """
  Token counts estimated from text, at four characters to a token, for where
  no provider has counted them: before a call is made, or for a call that
  ended before it reported what it used.
  """

  alias ReqLLM.Context
  alias Wardrik.LLM.Request

  @chars_per_token 4

  @doc "An estimate of how many tokens `messages` take: their text and their tool calls."
  @spec messages([ReqLLM.Message.t()]) :: non_neg_integer()
  def messages(messages) when is_list(messages), do: messages |> messages_chars() |> tokens()

  @doc """
  An estimate of how many tokens `request` sends: its messages, its system
  prompt and the tools it offers.
  """
  @spec request(Request.t()) :: non_neg_integer()
  def request(%Request{context: context, opts: opts}) do
    tokens(
      messages_chars(Context.to_list(context)) +
        text_chars(opts[:system_prompt]) +
        tools_chars(opts[:tools])
    )
  end

  @doc "An estimate of how many tokens `text` takes."
  @spec text(String.t()) :: non_neg_integer()
  def text(text) when is_binary(text), do: tokens(String.length(text))

  @doc "How many characters of text come to about `tokens` tokens."
  @spec chars(non_neg_integer()) :: non_neg_integer()
  def chars(tokens) when is_integer(tokens) and tokens >= 0, do: tokens * @chars_per_token

  defp tokens(chars), do: div(chars, @chars_per_token)

  defp messages_chars(messages), do: Enum.reduce(messages, 0, &(message_chars(&1) + &2))

  defp message_chars(%{content: content} = message) do
    text_chars(content) + calls_chars(Map.get(message, :tool_calls))
  end

  defp text_chars(content) when is_binary(content), do: String.length(content)

  defp text_chars(parts) when is_list(parts) do
    Enum.reduce(parts, 0, fn
      %{text: text}, sum when is_binary(text) -> sum + String.length(text)
      _other, sum -> sum
    end)
  end

  defp text_chars(_content), do: 0

  defp calls_chars(calls) when is_list(calls), do: calls |> inspect() |> String.length()
  defp calls_chars(_calls), do: 0

  defp tools_chars(tools) when is_list(tools), do: Enum.reduce(tools, 0, &(tool_chars(&1) + &2))
  defp tools_chars(_tools), do: 0

  defp tool_chars(tool),
    do: tool |> Map.take([:name, :description, :parameter_schema]) |> inspect() |> String.length()
end
