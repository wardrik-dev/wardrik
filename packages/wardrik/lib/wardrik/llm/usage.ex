defmodule Wardrik.LLM.Usage do
  @moduledoc """
  What a model call used, as `ReqLLM.Response.usage/1` reports it.

  A call that ends without the provider reporting what it used, because it was
  interrupted, failed part way through its answer, or came back with no
  usage, is counted as `Wardrik.LLM.Tokens` estimates it from the request and the
  text that streamed. A call that failed before the provider began to answer
  used nothing.
  """

  alias Wardrik.LLM.Dispatch
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Tokens

  @doc "What `request` used, ending as `outcome`, or `nil` where it used nothing."
  @spec of(Request.t(), Dispatch.outcome()) :: map() | nil
  def of(%Request{} = request, {:ok, response}) do
    usage = ReqLLM.Response.usage(response)

    if reported?(usage),
      do: usage,
      else: estimate(request, Tokens.messages(List.wrap(response.message)))
  end

  def of(%Request{} = request, {:interrupted, text}), do: estimate(request, Tokens.text(text))
  def of(%Request{} = request, {:error, _reason, text}), do: estimate(request, Tokens.text(text))
  def of(%Request{}, {:error, _reason}), do: nil

  @doc "The tokens `usage` counts, input and output together."
  @spec tokens(map()) :: non_neg_integer()
  def tokens(usage) when is_map(usage),
    do: count(usage, :input_tokens) + count(usage, :output_tokens)

  defp reported?(%{} = usage), do: is_number(usage[:total_cost]) or tokens(usage) > 0
  defp reported?(_usage), do: false

  defp estimate(request, output_tokens),
    do: %{input_tokens: Tokens.request(request), output_tokens: output_tokens}

  defp count(usage, key) do
    case Map.get(usage, key) do
      n when is_integer(n) and n >= 0 -> n
      _missing -> 0
    end
  end
end
