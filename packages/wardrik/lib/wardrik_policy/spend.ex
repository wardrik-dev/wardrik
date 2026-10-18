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

  @doc """
  The name of `agent`'s spend against the budget `meter` names in `window`,
  as a meter is keyed: the agent's, never one conversation's, so an agent and
  every conversation it answers for spend from one meter. Each budget the
  agent is held to has its own, so two budgets never count one call twice,
  and more granted to one loosens no other.
  """
  @spec key(Wardrik.AgentID.t(), String.t(), String.t()) :: String.t()
  def key(%Wardrik.AgentID{} = agent, meter, window),
    do: "#{Wardrik.AgentID.put_external_id(agent, nil)}|#{meter}|#{window}"

  @doc """
  The name of what every agent under `prefix` has spent together against the
  budget `meter` names in `window`, as a meter is keyed: one meter for all of
  them, apart from each agent's own.
  """
  @spec pooled(Wardrik.AgentID.Prefix.t(), String.t(), String.t()) :: String.t()
  def pooled(prefix, meter, window), do: "#{prefix}|#{meter}|#{window}"

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
