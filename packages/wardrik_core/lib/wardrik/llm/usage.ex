defmodule Wardrik.LLM.Usage do
  @moduledoc """
  What a model call used: the tokens it read and wrote, the share of those
  read from the provider's cache and spent on reasoning, and what it cost in
  US dollars where the provider says. A count the provider gave no figure
  for is `nil`.

  A call that ends without the provider reporting what it used, because it was
  interrupted, failed part way through its answer, or came back with no
  usage, is counted as `Wardrik.LLM.Tokens` estimates it from the request and the
  text that streamed. A call that failed before the provider began to answer
  used nothing.
  """

  alias Wardrik.LLM.Answer
  alias Wardrik.LLM.Dispatch
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Tokens

  defstruct [:input_tokens, :output_tokens, :cached_tokens, :reasoning_tokens, :total_cost]

  @type t() :: %__MODULE__{
          input_tokens: non_neg_integer() | nil,
          output_tokens: non_neg_integer() | nil,
          cached_tokens: non_neg_integer() | nil,
          reasoning_tokens: non_neg_integer() | nil,
          total_cost: number() | nil
        }

  @doc "What `request` used, ending as `outcome`, or `nil` where it used nothing."
  @spec of(Request.t(), Dispatch.outcome()) :: t() | nil
  def of(%Request{} = request, {:ok, %Answer{usage: usage, message: message}}) do
    if reported?(usage),
      do: usage,
      else: estimate(request, Tokens.messages([message]))
  end

  def of(%Request{} = request, {:interrupted, text}), do: estimate(request, Tokens.text(text))
  def of(%Request{} = request, {:error, _reason, text}), do: estimate(request, Tokens.text(text))
  def of(%Request{}, {:error, _reason}), do: nil

  @doc "The tokens `usage` counts, input and output together."
  @spec tokens(t()) :: non_neg_integer()
  def tokens(%__MODULE__{} = usage), do: count(usage.input_tokens) + count(usage.output_tokens)

  defp reported?(%__MODULE__{} = usage), do: is_number(usage.total_cost) or tokens(usage) > 0
  defp reported?(nil), do: false

  defp estimate(request, output_tokens),
    do: %__MODULE__{input_tokens: Tokens.request(request), output_tokens: output_tokens}

  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(_missing), do: 0
end
