if Code.ensure_loaded?(Wardrik.Context) do
  defmodule Wardrik.Policy.Spending do
    @moduledoc false

    alias Wardrik.Context
    alias Wardrik.Policy.Budget
    alias Wardrik.Policy.Decision
    alias Wardrik.Policy.Spending.Counted
    alias Wardrik.Policy.Spending.Spent

    @spec start(Context.t(), [Wardrik.Policy.t()]) :: Context.t()
    def start(context, policies) do
      spent = handle_spend(context)

      current =
        policies
        |> collect_budgets()
        |> Map.new(fn {key, policy} ->
          {key, current(spent[key], period(policy.budget, context))}
        end)

      Context.put_private(context, Spent, current)
    end

    @spec explain(Context.t(), [Wardrik.Policy.t()]) :: Decision.t()
    def explain(context, policies) do
      spent = handle_spend(context)

      policies
      |> collect_budgets()
      |> Enum.map(fn {key, policy} -> decision(policy, spent[key]) end)
      |> Enum.reject(&is_nil/1)
      |> Decision.strictest()
    end

    @spec grant(Context.t(), [Wardrik.Policy.t()]) :: Context.t()
    def grant(context, policies), do: update(context, policies, &Budget.grant/2)

    @spec record(Context.t(), [Wardrik.Policy.t()]) :: Context.t()
    def record(context, policies) do
      gained = compute_gain(context)
      count(context, policies, &spend(&1, &2, gained))
    end

    @spec catch_up(Context.t(), [Wardrik.Policy.t()]) :: Context.t()
    def catch_up(context, policies) do
      gained = compute_gain(context)

      count(context, policies, fn budget, spent ->
        %{spend(budget, spent, gained) | unpriced: spent.unpriced}
      end)
    end

    defp count(context, policies, spend) do
      context
      |> update(policies, spend)
      |> Context.put_private(Counted, %{trace: trace(context), counted: context.measurements})
    end

    defp collect_budgets(policies) do
      for {%Wardrik.Policy{budget: %Budget{}} = policy, index} <- Enum.with_index(policies),
          do: {policy.name || index, policy}
    end

    defp handle_spend(context), do: Context.get_private(context, Spent, %{})

    defp period(%Budget{per: :turn}, context), do: {:turn, ask(context.messages)}
    defp period(budget, _context), do: Budget.period(budget, DateTime.utc_now())

    defp ask(messages), do: Enum.count(messages, &(&1.role == :user))

    defp current(%{period: period} = spent, period), do: spent

    defp current(_spent, period),
      do: %{period: period, usd: 0, tokens: 0, granted: %{}, unpriced: false}

    defp decision(%Wardrik.Policy{budget: %Budget{usd: usd, price: nil}} = policy, %{
           unpriced: true
         })
         when usd != nil do
      %Decision{
        effect: :deny,
        message: "This model has no price in dollars, so the budget can't hold it.",
        policy: policy.name,
        cause: :budget
      }
    end

    defp decision(policy, spent), do: exhaust(policy, Budget.check(policy.budget, spent))

    defp exhaust(_policy, :allow), do: nil

    defp exhaust(policy, {effect, message}),
      do: %Decision{effect: effect, message: message, policy: policy.name, cause: :budget}

    defp compute_gain(context) do
      counted = handle_count(Context.get_private(context, Counted), trace(context))

      context.measurements
      |> Map.new(fn {key, amount} -> {key, amount - Map.get(counted, key, 0)} end)
      |> Map.reject(fn {_key, amount} -> amount == 0 end)
    end

    defp handle_count(%{trace: trace, counted: counted}, trace), do: counted
    defp handle_count(_counted, _trace), do: %{}

    defp trace(%Context{span: nil}), do: nil
    defp trace(%Context{span: span}), do: span.trace

    defp spend(_budget, spent, gained) when map_size(gained) == 0, do: spent

    defp spend(budget, spent, gained) do
      cost = cost(budget, gained)
      tokens = Map.get(gained, :input_tokens, 0) + Map.get(gained, :output_tokens, 0)

      %{
        spent
        | usd: spent.usd + (cost || 0),
          tokens: spent.tokens + tokens,
          unpriced: spent.unpriced or cost == nil
      }
    end

    defp cost(budget, %{unpriced_calls: _calls} = gained),
      do: Budget.cost(budget, Map.delete(gained, :usd))

    defp cost(_budget, gained), do: Map.get(gained, :usd, 0)

    defp update(context, policies, fun) do
      spent =
        policies
        |> collect_budgets()
        |> Enum.reduce(handle_spend(context), fn {key, policy}, spent ->
          Map.update!(spent, key, &fun.(policy.budget, &1))
        end)

      Context.put_private(context, Spent, spent)
    end
  end
end
