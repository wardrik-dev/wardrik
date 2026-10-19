defmodule WardrikPolicy.Ceiling do
  @moduledoc """
  An org's budget, which every agent of the org spends from together, as
  `WardrikPolicy.ceiling/2` gives it.

  It is a `WardrikPolicy.Budget` counted under one meter for the whole
  tenant, `acme/*`, rather than one for each agent: the org's own agents and
  each of its users' spend from it alike. Once they have spent its limit
  together, the next model call any of them makes is stopped, and approving
  it grants the budget's `grant` more to all of them for that period. Each
  agent's own budget still counts apart, beside it.
  """

  use Wardrik.Hook

  alias Wardrik.Call
  alias WardrikPolicy.Budget
  alias WardrikPolicy.Spend

  @enforce_keys [:budget, :org]
  defstruct [:budget, :org]

  @type t() :: %__MODULE__{budget: Budget.t(), org: String.t()}

  @doc "The ceiling `budget` puts on every agent of `org` together."
  @spec new(Budget.t(), String.t()) :: t()
  def new(%Budget{} = budget, org), do: %__MODULE__{budget: budget, org: org}

  @impl Wardrik.Hook
  def init(%__MODULE__{} = ceiling), do: ceiling

  @impl Wardrik.Hook
  def call(%Call{run: run} = call, %__MODULE__{} = ceiling) do
    Budget.check(ceiling.budget, call,
      key: key(ceiling, run.source.trace.trace_id),
      spender: "#{ceiling.org}'s agents have spent"
    )
  end

  @impl Wardrik.Hook
  def approved(%Call{} = call, memo, %__MODULE__{} = ceiling),
    do: Budget.approved(call, memo, ceiling.budget)

  @impl Wardrik.Hook
  def settle(%Call{run: run} = call, %__MODULE__{} = ceiling),
    do: Budget.record(ceiling.budget, call, key: key(ceiling, run.source.trace.trace_id))

  @doc """
  What the org's agents have spent together in the ceiling's period now, or
  `nil` for a ceiling per turn, which no one period holds.
  """
  @spec spent(t()) :: Spend.t() | nil
  def spent(%__MODULE__{budget: %Budget{per: :turn}}), do: nil
  def spent(%__MODULE__{} = ceiling), do: ceiling |> key("") |> Budget.read()

  @doc """
  What `agent`'s org has spent together against the ceiling, as a phrase:
  `$12.40 of $20.00 today across acme`. Read beside each agent's own
  budgets, as `WardrikPolicy.Budget.spending/2` gives them.
  """
  @spec spending(t(), Wardrik.AgentID.t()) :: String.t() | nil
  def spending(%__MODULE__{} = ceiling, %Wardrik.AgentID{}) do
    case spent(ceiling) do
      nil ->
        nil

      %Spend{} = spend ->
        "#{Budget.said(ceiling.budget, spend)} across #{ceiling.org}"
    end
  end

  defp key(ceiling, trace_id) do
    Spend.pooled(
      Wardrik.Resource.parse!(ceiling.org <> "/*"),
      ceiling.budget.meter,
      Budget.window(ceiling.budget, trace_id, DateTime.utc_now())
    )
  end
end
