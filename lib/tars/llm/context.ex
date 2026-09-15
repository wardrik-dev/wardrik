defmodule Tars.LLM.Context do
  @moduledoc """
  Manipulates ReqLLM.Context{}
  """

  def append_user_message(%ReqLLM.Context{} = context, message) do
    user_message = ReqLLM.Context.user(message)
    ReqLLM.Context.append(context, user_message)
  end

  @doc "The text parts of a message joined, or `\"\"` for one with none."
  @spec text(ReqLLM.Message.t()) :: String.t()
  def text(%{content: parts}) when is_list(parts) do
    parts
    |> Enum.filter(&(&1.type == :text))
    |> Enum.map_join(& &1.text)
  end

  def text(%{content: content}) when is_binary(content), do: content
end
