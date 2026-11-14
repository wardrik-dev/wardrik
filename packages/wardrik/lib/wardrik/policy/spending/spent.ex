defmodule Wardrik.Policy.Spending.Spent do
  @moduledoc false

  # What an agent spent against each of its budgets, kept as its private data, by the budget's
  # policy name or place.

  @behaviour Wardrik.Format

  @pers %{"day" => :day, "week" => :week, "month" => :month}

  @impl Wardrik.Format
  def type, do: "policy_spent"

  @impl Wardrik.Format
  def version, do: 1

  @impl Wardrik.Format
  def dump(spent) do
    for {policy, budget} <- spent do
      %{
        "policy" => policy,
        "period" => period(budget.period),
        "usd" => budget.usd,
        "tokens" => budget.tokens,
        "granted" =>
          Map.new(budget.granted, fn {kind, amount} -> {Atom.to_string(kind), amount} end),
        "unpriced" => budget.unpriced
      }
    end
  end

  @impl Wardrik.Format
  def load(1, spent) do
    {:ok,
     Map.new(spent, fn budget ->
       {budget["policy"],
        %{
          period: read_period(budget["period"]),
          usd: budget["usd"],
          tokens: budget["tokens"],
          granted: Map.new(budget["granted"], fn {kind, amount} -> {kind(kind), amount} end),
          unpriced: budget["unpriced"]
        }}
     end)}
  end

  defp period(:turn), do: "turn"
  defp period(:total), do: "total"
  defp period({:turn, asked}), do: %{"turn" => asked}

  defp period({per, %Date{} = starts}),
    do: %{"per" => Atom.to_string(per), "starts" => Date.to_iso8601(starts)}

  defp read_period("turn"), do: :turn
  defp read_period("total"), do: :total
  defp read_period(%{"turn" => asked}), do: {:turn, asked}

  defp read_period(%{"per" => per, "starts" => starts}),
    do: {Map.fetch!(@pers, per), Date.from_iso8601!(starts)}

  defp kind("usd"), do: :usd
  defp kind("tokens"), do: :tokens
end
