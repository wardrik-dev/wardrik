defmodule WardrikPolicy.BudgetTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias ReqLLM.Context
  alias Wardrik.Call
  alias Wardrik.Hook
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Cost
  alias Wardrik.LLM.Dispatch
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Tokens
  alias Wardrik.Scope
  alias Wardrik.Test.LLMStub
  alias WardrikPolicy.Budget
  alias WardrikPolicy.Spend

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

  describe "as a hook" do
    setup do
      agent = Wardrik.AgentID.parse!("budget-#{System.unique_integer([:positive])}/triage")

      on_exit(fn ->
        for key <- Wardrik.Store.keys(:budgets, to_string(agent)),
            do: Wardrik.Store.delete(:budgets, key)
      end)

      policy = WardrikPolicy.decode!(%{"budget" => %{"usd" => 1.0, "grant" => %{"usd" => 0.5}}})
      scope = Scope.root(Config.new(), agent, hooks: WardrikPolicy.hooks(policy))

      %{
        budget: policy.budget,
        scope: scope,
        request: Request.new(Config.new(), Context.new())
      }
    end

    defp costing(usd) do
      %{
        LLMStub.final_answer("done")
        | usage: %{input_tokens: 10, output_tokens: 5, total_cost: usd}
      }
    end

    defp under(scope, policy), do: %{scope | hooks: WardrikPolicy.hooks(policy)}

    defp approve(waiting, scope),
      do: waiting |> Call.approve() |> Call.under(scope) |> Hook.approved()

    test "is named for its policy, after the policy's rules" do
      policy = WardrikPolicy.decode!(%{"budget" => %{"usd" => 1.0}}, "careful")

      assert [
               %Hook{name: "careful", module: WardrikPolicy},
               %Hook{name: "careful/budget"} = budget
             ] =
               WardrikPolicy.hooks(policy)

      assert budget.module == Budget
      assert budget.value == policy.budget
      assert [%Hook{name: "policy"}] = WardrikPolicy.hooks(WardrikPolicy.decode!(%{}))
    end

    test "admits calls until the period's spend reaches the limit", context do
      %{scope: scope, request: request} = context

      assert {:ok, ^request} = Dispatch.admit(scope, request)

      :ok = Dispatch.settle(scope, request, {:ok, costing(0.6)})
      assert {:ok, ^request} = Dispatch.admit(scope, request)

      :ok = Dispatch.settle(scope, request, {:ok, costing(0.6)})

      assert {:park, waiting} = Dispatch.admit(scope, request)

      assert [
               %Call.Ask{
                 by: "policy/budget",
                 prompt:
                   "This agent has spent $1.20 of $1.00 today. Approve to allow $0.50 more.",
                 memo: "budget-" <> _key
               }
             ] = waiting.asks
    end

    test "approving grants more for the period the call was asked in", context do
      %{budget: budget, scope: scope, request: request} = context

      :ok = Dispatch.settle(scope, request, {:ok, costing(1.2)})
      assert {:park, waiting} = Dispatch.admit(scope, request)

      :ok = approve(waiting, scope)

      assert {:ok, ^request} = Dispatch.admit(scope, request)

      assert %Spend{micro_usd: 1_200_000, granted_micro_usd: 500_000} =
               Budget.spent(budget, scope)

      assert Budget.spending(budget, scope.source.agent_id) == "$1.20 of $1.50 today"
    end

    test "a budget that denies ends the turn instead of parking", context do
      %{scope: scope, request: request} = context

      scope =
        under(
          scope,
          WardrikPolicy.decode!(%{"budget" => %{"usd" => 1.0, "on_exhausted" => "deny"}})
        )

      :ok = Dispatch.settle(scope, request, {:ok, costing(1.0)})

      assert {:error, {:policy_denied, "This agent has spent $1.00 of $1.00 today."}} =
               Dispatch.admit(scope, request)
    end

    test "a call that failed before it was answered spends nothing", context do
      %{budget: budget, scope: scope, request: request} = context

      :ok = Dispatch.settle(scope, request, {:error, :timeout})

      assert %Spend{micro_usd: 0, tokens: 0} = Budget.spent(budget, scope)
    end

    test "a call that ended without reporting what it used is counted as estimated", context do
      %{budget: budget, scope: scope} = context
      model = {:anthropic, model: "claude-sonnet-5"}
      streamed = String.duplicate("a", 400)

      request =
        Request.new(
          Config.new(model_spec: model, system: String.duplicate("s", 400)),
          Context.new([Context.user(String.duplicate("q", 4000))])
        )

      input = Tokens.request(request)
      output = Tokens.text(streamed)
      each = Budget.micro(Cost.of(model, %{input_tokens: input, output_tokens: output}))

      :ok = Dispatch.settle(scope, request, {:interrupted, streamed})
      :ok = Dispatch.settle(scope, request, {:error, :closed, streamed})
      :ok = Dispatch.settle(scope, request, {:ok, LLMStub.final_answer(streamed)})

      assert input == 1100 and output == 100 and each > 0
      assert %Spend{micro_usd: micro_usd, tokens: tokens} = Budget.spent(budget, scope)
      assert tokens == 3 * (input + output)
      assert micro_usd == 3 * each
    end

    test "a budget in dollars refuses a model the catalog cannot price", context do
      %{scope: scope} = context

      request = Request.new(Config.new(model_spec: "nowhere:no-such-model"), Context.new())

      assert {:error, {:policy_denied, "This agent's budget is in dollars" <> _}} =
               Dispatch.admit(scope, request)

      in_tokens = under(scope, WardrikPolicy.decode!(%{"budget" => %{"tokens" => 1000}}))
      assert {:ok, ^request} = Dispatch.admit(in_tokens, request)
    end

    test "a token limit governs a call that costs nothing in dollars", context do
      %{scope: scope, request: request} = context
      scope = under(scope, WardrikPolicy.decode!(%{"budget" => %{"tokens" => 20}}))

      :ok = Dispatch.settle(scope, request, {:ok, costing(0.0)})
      assert {:ok, ^request} = Dispatch.admit(scope, request)

      :ok = Dispatch.settle(scope, request, {:ok, costing(0.0)})

      assert {:park, waiting} = Dispatch.admit(scope, request)

      assert Call.prompt(waiting) ==
               "This agent has spent 30 of 20 tokens today. Approve to allow 20 tokens more."

      :ok = approve(waiting, scope)
      assert {:ok, ^request} = Dispatch.admit(scope, request)
    end

    test "allows every tool call", context do
      %{scope: scope} = context
      call = Call.tool(%{id: "call_1", name: "deploy", arguments: %{}}, scope)

      assert %Call{state: :allowed} = Hook.check(call)
    end

    test "approving a tool call grants nothing, since no budget asked about it", context do
      %{budget: budget, scope: scope} = context
      call = Call.tool(%{id: "call_1", name: "deploy", arguments: %{}}, scope)

      assert :ok = Budget.approved(call, nil, budget)
    end

    test "a grant the meter cannot record is logged, and the approval stands", context do
      %{budget: budget, scope: scope, request: request} = context
      stub(WardrikPolicy.Meter, :grant, fn _key, _usd, _tokens -> {:error, :no_capacity} end)

      log = capture_log(fn -> Budget.approved(Call.model(request, scope), "day:x", budget) end)

      assert log =~ "granted more budget that was not recorded"
    end

    test "calls settling at once each count, with nothing retried", context do
      %{budget: budget, scope: scope, request: request} = context

      1..200
      |> Task.async_stream(
        fn _ -> Dispatch.settle(scope, request, {:ok, costing(0.01)}) end,
        max_concurrency: 200
      )
      |> Stream.run()

      assert %Spend{tokens: 3000, micro_usd: 2_000_000} = Budget.spent(budget, scope)
    end

    test "a budget whose meter cannot be read refuses the call", context do
      %{scope: scope, request: request} = context

      stub(WardrikPolicy.Meter, :read, fn _key -> {:error, {:meter_unavailable, :no_capacity}} end)

      assert {:error, {:policy_denied, "This agent's budget could not be read" <> _}} =
               Dispatch.admit(scope, request)
    end
  end

  test "a budget is part of a policy's written form" do
    written = %{
      "budget" => %{"usd" => 5.0, "tokens" => 1000, "per" => "day", "on_exhausted" => "ask"},
      "default" => "allow"
    }

    assert written |> WardrikPolicy.decode!() |> WardrikPolicy.encode() == written
  end
end
