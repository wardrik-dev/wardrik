defmodule WardrikPolicy.BudgetTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias ReqLLM.Context
  alias Wardrik.Call
  alias Wardrik.Call.Pipeline
  alias Wardrik.Hook
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Cost
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
        for key <- WardrikStore.keys(:budgets, to_string(agent)),
            do: WardrikStore.delete(:budgets, key)
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

    # The model call `request` makes under `scope`, as its hooks decide it.
    defp decide(scope, request), do: request |> Pipeline.model(scope) |> Pipeline.decide()

    # A model call its hooks let go ahead under `scope`, which ended as
    # `outcome`, and which they hear.
    defp spend(scope, request, outcome) do
      %{Pipeline.model(request, scope) | state: :allowed}
      |> Pipeline.run(&Call.answer(&1, outcome))
    end

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

      assert %Call{state: :allowed} = decide(scope, request)

      spend(scope, request, {:ok, costing(0.6)})
      assert %Call{state: :allowed} = decide(scope, request)

      spend(scope, request, {:ok, costing(0.6)})

      assert %Call{state: :waiting} = waiting = decide(scope, request)

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

      spend(scope, request, {:ok, costing(1.2)})
      assert %Call{state: :waiting} = waiting = decide(scope, request)

      :ok = approve(waiting, scope)

      assert %Call{state: :allowed} = decide(scope, request)

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

      spend(scope, request, {:ok, costing(1.0)})

      assert %Call{
               state: :denied,
               denied: %{reason: "This agent has spent $1.00 of $1.00 today."}
             } =
               decide(scope, request)
    end

    test "a call that failed before it was answered spends nothing", context do
      %{budget: budget, scope: scope, request: request} = context

      spend(scope, request, {:error, :timeout})

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

      spend(scope, request, {:interrupted, streamed})
      spend(scope, request, {:error, :closed, streamed})
      spend(scope, request, {:ok, LLMStub.final_answer(streamed)})

      assert input == 1100 and output == 100 and each > 0
      assert %Spend{micro_usd: micro_usd, tokens: tokens} = Budget.spent(budget, scope)
      assert tokens == 3 * (input + output)
      assert micro_usd == 3 * each
    end

    test "counts a model call at the cost the call carries, as its event does", context do
      %{budget: budget, scope: scope, request: request} = context

      made = spend(scope, request, {:ok, costing(0.0123)})

      assert made.cost == %{micro_usd: 12_300, source: :provider}
      assert %Spend{micro_usd: 12_300} = Budget.spent(budget, scope)
    end

    test "counts a tool call, failed or not, at the price its tool reported or the config lists",
         context do
      %{budget: budget, scope: scope} = context

      search =
        Wardrik.Tool.new!(
          name: "search",
          description: "Searches, at a price.",
          parameter_schema: [],
          run: fn _input, _context -> Wardrik.Tool.Result.ok(%{"hits" => 1}, cost: 0.004) end
        )

      free =
        Wardrik.Tool.new!(
          name: "free",
          description: "Costs nothing it knows of.",
          parameter_schema: [],
          run: fn _input, _context -> Wardrik.Tool.Result.ok(%{}) end
        )

      declined =
        Wardrik.Tool.new!(
          name: "charge",
          description: "Fails, and is charged.",
          parameter_schema: [],
          run: fn _input, _context -> {:error, "Declined.", cost: 0.25} end
        )

      listed =
        Wardrik.Tool.new!(
          name: "lookup",
          description: "Says nothing of cost; the config lists it.",
          parameter_schema: [],
          run: fn _input, _context -> {:error, "Not found."} end
        )

      config =
        Config.new(tools: [search, free, declined, listed], tool_prices: %{"lookup" => 0.1})

      scope = %{scope | config: config}

      for {id, name} <- [
            {"c1", "search"},
            {"c2", "free"},
            {"c3", "search"},
            {"c4", "charge"},
            {"c5", "lookup"}
          ] do
        %{Call.tool(%{id: id, name: name, arguments: %{}}, scope) | state: :allowed}
        |> Pipeline.run()
      end

      assert %Spend{micro_usd: 358_000, tokens: 0} = Budget.spent(budget, scope)
    end

    test "a budget in dollars refuses a model the catalog cannot price", context do
      %{scope: scope} = context

      request = Request.new(Config.new(model_spec: "nowhere:no-such-model"), Context.new())

      assert %Call{state: :denied, denied: %{reason: "This agent's budget is in dollars" <> _}} =
               decide(scope, request)

      in_tokens = under(scope, WardrikPolicy.decode!(%{"budget" => %{"tokens" => 1000}}))
      assert %Call{state: :allowed} = decide(in_tokens, request)
    end

    test "a token limit governs a call that costs nothing in dollars", context do
      %{scope: scope, request: request} = context
      scope = under(scope, WardrikPolicy.decode!(%{"budget" => %{"tokens" => 20}}))

      spend(scope, request, {:ok, costing(0.0)})
      assert %Call{state: :allowed} = decide(scope, request)

      spend(scope, request, {:ok, costing(0.0)})

      assert %Call{state: :waiting} = waiting = decide(scope, request)

      assert Call.prompt(waiting) ==
               "This agent has spent 30 of 20 tokens today. Approve to allow 20 tokens more."

      :ok = approve(waiting, scope)
      assert %Call{state: :allowed} = decide(scope, request)
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

    test "hearing what a tool call did spends nothing", context do
      %{budget: budget, scope: scope} = context
      call = Call.tool(%{id: "call_1", name: "deploy", arguments: %{}}, scope)

      assert :ok = Budget.settle(Call.answer(call, {:ok, "deployed"}), budget)
      assert %Spend{micro_usd: 0, tokens: 0} = Budget.spent(budget, scope)
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
        fn _ -> spend(scope, request, {:ok, costing(0.01)}) end,
        max_concurrency: 200
      )
      |> Stream.run()

      assert %Spend{tokens: 3000, micro_usd: 2_000_000} = Budget.spent(budget, scope)
    end

    test "a budget whose meter cannot be read refuses the call", context do
      %{scope: scope, request: request} = context

      stub(WardrikPolicy.Meter, :read, fn _key -> {:error, {:meter_unavailable, :no_capacity}} end)

      assert %Call{
               state: :denied,
               denied: %{reason: "This agent's budget could not be read" <> _}
             } =
               decide(scope, request)
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
