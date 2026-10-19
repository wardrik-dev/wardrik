defmodule Wardrik.LLM.Cost do
  @moduledoc """
  What a model call cost, in US dollars.

      Wardrik.LLM.Cost.of(Wardrik.Host.llm(host), request.model_spec, answer.usage)
      #=> 0.0042

  The provider's own `total_cost` when it reports one; otherwise the tokens
  priced by the host's `Wardrik.LLM.Client`, as `Wardrik.LLM.Client.price/3`
  prices them. A model the client does not price costs `nil`, which is not
  the same as nothing: a host enforcing a budget decides what an unpriced
  call counts as.

  `price/3` is the same figure as a call keeps it, `t:Wardrik.Call.cost/0`:
  whole micro-dollars, and whether the provider reported it or the client
  priced it. A call's events carry that figure, and a budget counts it, so
  the two never disagree.
  """

  alias Wardrik.LLM.Client
  alias Wardrik.LLM.Usage

  @doc """
  The cost of a call to `model_spec` that used `usage`, as `client` prices
  it, or `nil` where it cannot be priced.
  """
  @spec of(Client.t(), term(), Usage.t() | nil) :: float() | nil
  def of(_client, _model_spec, nil), do: nil
  def of(_client, _model_spec, %Usage{total_cost: total}) when is_number(total), do: total / 1
  def of(client, model_spec, %Usage{} = usage), do: Client.price(client, model_spec, usage)

  @doc """
  The cost of a call to `model_spec` that used `usage`, as a call keeps it,
  or `nil` where it cannot be priced.
  """
  @spec price(Client.t(), term(), Usage.t() | nil) :: Wardrik.Call.cost() | nil
  def price(_client, _model_spec, nil), do: nil

  def price(_client, _model_spec, %Usage{total_cost: total}) when is_number(total),
    do: %{micro_usd: micro(total), source: :provider}

  def price(client, model_spec, %Usage{} = usage) do
    case of(client, model_spec, usage) do
      nil -> nil
      usd -> %{micro_usd: micro(usd), source: :catalog}
    end
  end

  @doc "`usd` dollars in whole micro-dollars, rounded to the nearest."
  @spec micro(number()) :: non_neg_integer()
  def micro(usd), do: round(usd * 1_000_000)

  @doc """
  Whether `client` prices `model_spec`, so that `of/3` can price a call to
  it from its tokens.
  """
  @spec priced?(Client.t(), term()) :: boolean()
  def priced?(client, model_spec),
    do: Client.price(client, model_spec, %Usage{input_tokens: 1, output_tokens: 1}) != nil
end
