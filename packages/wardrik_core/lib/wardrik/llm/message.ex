defmodule Wardrik.LLM.Message do
  @moduledoc "Reads a `ReqLLM.Message`."

  @doc "The text parts of a message joined, or `\"\"` for one with none."
  @spec text(ReqLLM.Message.t()) :: String.t()
  def text(%{content: parts}) when is_list(parts) do
    parts
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join(& &1.text)
  end

  def text(%{content: content}) when is_binary(content), do: content

  @doc """
  What a turn that produced `messages` answered: the text of its last
  assistant message that said something. A turn that ended in tool calls
  alone leaves nothing to report, which is an empty answer, `\"\"`, rather
  than an error.
  """
  @spec answer([ReqLLM.Message.t()]) :: String.t()
  def answer(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn
      %{role: :assistant} = message -> presence(text(message))
      _message -> nil
    end)
  end

  defp presence(""), do: nil
  defp presence(text), do: text
end
