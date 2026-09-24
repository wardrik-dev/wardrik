defmodule TarsPolicy.BudgetTest do
  use ExUnit.Case, async: false
  use Mimic

  alias ReqLLM.Context
  alias Tars.LLM.Config
  alias Tars.LLM.Request
  alias Tars.Scope
  alias Tars.Test.LLMStub
  alias TarsPolicy.Budget
  alias TarsPolicy.Spend

  describe "decode/1 and encode/1" do
    test "round-trip, with the defaults filled in" do
      assert {:ok, budget} = Budget.decode(%{"usd" => 5})
      assert budget == %Budget{usd: 5.0, per: :day, on_exhausted: :ask}
      assert Budget.grant(budget) == {5_000_000, 0}

      full = %{
        "usd" => 2.5,
        "tokens" => 100_000,
        "per" => "week",
        "grant" => %{"usd" => 1, "tokens" => 5000},
        "on_exhausted" => "deny"
      }

      assert {:ok, budget} = Budget.decode(full)
      assert Budget.grant(budget) == {1_000_000, 5000}
      assert Budget.decode(Budget.encode(budget)) == {:ok, budget}

      assert {:ok, tokens_only} = Budget.decode(%{"tokens" => 1000})
      assert Budget.grant(tokens_only) == {0, 1000}
    end

    test "refuse what they cannot read" do
      assert {:error, "budget sets usd, tokens, or both"} = Budget.decode(%{})
      assert {:error, "budget tokens is a whole number" <> _} = Budget.decode(%{"tokens" => 1.5})

      assert {:error, "budget grant minutes is not a setting" <> _} =
               Budget.decode(%{"usd" => 1, "grant" => %{"minutes" => 1}})

      assert {:error, "budget usd is a number" <> _} = Budget.decode(%{"usd" => 0})
      assert {:error, "budget per is " <> _} = Budget.decode(%{"usd" => 1, "per" => "hour"})

      assert {:error, "budget on_exhausted is ask or deny"} =
               Budget.decode(%{"usd" => 1, "on_exhausted" => "no"})

      assert {:error, "budget dollars is not a setting" <> _} =
               Budget.decode(%{"usd" => 1, "dollars" => 1})
    end
  end

  test "window/3 names the UTC period a moment falls in" do
    now = ~U[2026-09-23 23:59:00Z]

    assert Budget.window(%Budget{usd: 1.0, per: :day}, "t1", now) == "day:2026-09-23"
    assert Budget.window(%Budget{usd: 1.0, per: :week}, "t1", now) == "week:2026-W39"
    assert Budget.window(%Budget{usd: 1.0, per: :month}, "t1", now) == "month:2026-09"
    assert Budget.window(%Budget{usd: 1.0, per: :turn}, "t1", now) == "turn:t1"
    assert Budget.window(%Budget{usd: 1.0, per: :total}, "t1", now) == "total"
  end

  describe "as a dispatch" do
    setup do
      agent = "budget-#{System.unique_integer([:positive])}/_/triage"

      on_exit(fn ->
        for key <- Tars.Store.keys(:budgets, agent), do: Tars.Store.delete(:budgets, key)
      end)

      policy = TarsPolicy.decode!(%{"budget" => %{"usd" => 1.0, "grant" => %{"usd" => 0.5}}})
      scope = Scope.root(Config.new(), agent, dispatch: {TarsPolicy, policy})
      %{policy: policy, scope: scope, request: Request.new(Config.new(), Context.new())}
    end

    defp costing(usd) do
      %{
        LLMStub.final_answer("done")
        | usage: %{input_tokens: 10, output_tokens: 5, total_cost: usd}
      }
    end

    test "admits calls until the period's spend reaches the limit", context do
      %{policy: policy, scope: scope, request: request} = context

      assert {:ok, ^request} = TarsPolicy.admit(request, scope, policy)

      :ok = TarsPolicy.settle(request, {:ok, costing(0.6)}, scope, policy)
      assert {:ok, ^request} = TarsPolicy.admit(request, scope, policy)

      :ok = TarsPolicy.settle(request, {:ok, costing(0.6)}, scope, policy)

      assert {:park, "This agent has spent $1.20 of $1.00 today. Approve to allow $0.50 more."} =
               TarsPolicy.admit(request, scope, policy)
    end

    test "approving grants more for the period", context do
      %{policy: policy, scope: scope, request: request} = context

      :ok = TarsPolicy.settle(request, {:ok, costing(1.2)}, scope, policy)
      assert {:park, _prompt} = TarsPolicy.admit(request, scope, policy)

      :ok = TarsPolicy.approved(request, scope, policy)

      assert {:ok, ^request} = TarsPolicy.admit(request, scope, policy)

      assert %Spend{micro_usd: 1_200_000, granted_micro_usd: 500_000} =
               TarsPolicy.spent(policy, scope)

      assert TarsPolicy.spending(policy, scope.source.agent_id) == "$1.20 of $1.50 today"
    end

    test "a budget that denies ends the turn instead of parking", context do
      %{scope: scope, request: request} = context
      policy = TarsPolicy.decode!(%{"budget" => %{"usd" => 1.0, "on_exhausted" => "deny"}})

      :ok = TarsPolicy.settle(request, {:ok, costing(1.0)}, scope, policy)

      assert {:error, {:policy_denied, "This agent has spent $1.00 of $1.00 today."}} =
               TarsPolicy.admit(request, scope, policy)
    end

    test "a call that failed spends nothing", context do
      %{policy: policy, scope: scope, request: request} = context

      :ok = TarsPolicy.settle(request, {:error, :timeout}, scope, policy)

      assert %Spend{micro_usd: 0, tokens: 0} = TarsPolicy.spent(policy, scope)
    end

    test "a token limit governs a call that costs nothing in dollars", context do
      %{scope: scope, request: request} = context
      policy = TarsPolicy.decode!(%{"budget" => %{"tokens" => 20}})

      :ok = TarsPolicy.settle(request, {:ok, costing(0.0)}, scope, policy)
      assert {:ok, ^request} = TarsPolicy.admit(request, scope, policy)

      :ok = TarsPolicy.settle(request, {:ok, costing(0.0)}, scope, policy)

      assert {:park,
              "This agent has spent 30 of 20 tokens today. Approve to allow 20 tokens more."} =
               TarsPolicy.admit(request, scope, policy)

      :ok = TarsPolicy.approved(request, scope, policy)
      assert {:ok, ^request} = TarsPolicy.admit(request, scope, policy)
    end

    test "a policy with no budget admits everything and records nothing", context do
      %{scope: scope, request: request} = context
      policy = TarsPolicy.decode!(%{})

      assert {:ok, ^request} = TarsPolicy.admit(request, scope, policy)
      assert :ok = TarsPolicy.settle(request, {:ok, costing(100.0)}, scope, policy)
      assert TarsPolicy.spent(policy, scope) == nil
    end

    test "calls settling at once each count, with nothing retried", context do
      %{policy: policy, scope: scope, request: request} = context

      1..200
      |> Task.async_stream(
        fn _ -> TarsPolicy.settle(request, {:ok, costing(0.01)}, scope, policy) end,
        max_concurrency: 200
      )
      |> Stream.run()

      assert %Spend{tokens: 3000, micro_usd: 2_000_000} = TarsPolicy.spent(policy, scope)
    end

    test "a budget whose meter cannot be read refuses the call", context do
      %{policy: policy, scope: scope, request: request} = context
      stub(TarsPolicy.Meter, :read, fn _key -> {:error, {:meter_unavailable, :no_capacity}} end)

      assert {:error, {:policy_denied, "This agent's budget could not be read" <> _}} =
               TarsPolicy.admit(request, scope, policy)
    end
  end

  test "a budget is part of a policy's written form" do
    written = %{
      "budget" => %{"usd" => 5.0, "tokens" => 1000, "per" => "day", "on_exhausted" => "ask"},
      "default" => "allow"
    }

    assert written |> TarsPolicy.decode!() |> TarsPolicy.encode() == written
  end
end
