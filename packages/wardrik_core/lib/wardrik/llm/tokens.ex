defmodule Wardrik.LLM.Tokens do
  @moduledoc """
  Token counts estimated from text, at four characters to a token, for where
  no provider has counted them: before a call is made, or for a call that
  ended before it reported what it used.
  """

  alias Wardrik.Conversation
  alias Wardrik.LLM.Request

  @chars_per_token 4

  @doc "An estimate of how many tokens `messages` take: their text, their reasoning and their tool calls."
  @spec messages([Conversation.message()]) :: non_neg_integer()
  def messages(messages) when is_list(messages), do: messages |> messages_chars() |> tokens()

  @doc """
  An estimate of every tail of `messages`, longest first: the one at index
  `n` is what `messages/1` makes of the messages from `n` on. Each message is
  counted once.
  """
  @spec tails([Conversation.message()]) :: [non_neg_integer()]
  def tails(messages) when is_list(messages) do
    {tails, _chars} =
      messages
      |> Enum.reverse()
      |> Enum.reduce({[], 0}, fn message, {tails, chars} ->
        chars = chars + message_chars(message)
        {[tokens(chars) | tails], chars}
      end)

    tails
  end

  @doc """
  An estimate of how many tokens `request` sends: its messages, its system
  prompt and the tools it offers.
  """
  @spec request(Request.t()) :: non_neg_integer()
  def request(%Request{context: context, opts: opts}) do
    tokens(
      messages_chars(Conversation.to_list(context)) +
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

  defp message_chars(%{parts: parts}), do: Enum.reduce(parts, 0, &(part_chars(&1) + &2))

  defp part_chars(%{text: text}), do: String.length(text)
  defp part_chars(%{arguments: _arguments} = call), do: call |> inspect() |> String.length()
  defp part_chars(_part), do: 0

  defp text_chars(text) when is_binary(text), do: String.length(text)
  defp text_chars(nil), do: 0

  defp tools_chars(tools) when is_list(tools), do: Enum.reduce(tools, 0, &(tool_chars(&1) + &2))
  defp tools_chars(nil), do: 0

  defp tool_chars(tool),
    do: tool |> Map.take([:name, :description, :schema]) |> inspect() |> String.length()
end
