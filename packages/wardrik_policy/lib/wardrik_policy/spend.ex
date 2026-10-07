defmodule WardrikPolicy.Spend do
  @moduledoc """
  What an agent has spent in one budget period, and what people have granted
  it beyond its limits there. `WardrikPolicy.Meter` holds one per period.

  Money is counted in whole micro-dollars, millionths of a US dollar, so any
  number of spends add up exactly.
  """

  defstruct micro_usd: 0, tokens: 0, granted_micro_usd: 0, granted_tokens: 0

  @type t() :: %__MODULE__{
          micro_usd: non_neg_integer(),
          tokens: non_neg_integer(),
          granted_micro_usd: non_neg_integer(),
          granted_tokens: non_neg_integer()
        }

  @doc "The name of `agent`'s spend in `window`, as a meter is keyed."
  @spec key(Wardrik.AgentID.t(), String.t()) :: String.t()
  def key(%Wardrik.AgentID{} = agent, window), do: "#{agent}|#{window}"

  @doc "The spend with `micro_usd` and `tokens` more spent."
  @spec spend(t(), non_neg_integer(), non_neg_integer()) :: t()
  def spend(%__MODULE__{} = spend, micro_usd, tokens),
    do: %{spend | micro_usd: spend.micro_usd + micro_usd, tokens: spend.tokens + tokens}

  @doc "The spend with `micro_usd` and `tokens` more granted."
  @spec grant(t(), non_neg_integer(), non_neg_integer()) :: t()
  def grant(%__MODULE__{} = spend, micro_usd, tokens) do
    %{
      spend
      | granted_micro_usd: spend.granted_micro_usd + micro_usd,
        granted_tokens: spend.granted_tokens + tokens
    }
  end
end
