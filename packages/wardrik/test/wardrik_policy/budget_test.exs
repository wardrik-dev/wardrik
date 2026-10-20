defmodule WardrikPolicy.BudgetTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Wardrik.Call
  alias Wardrik.Call.Pipeline
  alias Wardrik.Conversation
  alias Wardrik.Conversation.User
  alias Wardrik.Hook
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Cost
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Tokens
  alias Wardrik.LLM.Usage
  alias Wardrik.Run
  alias Wardrik.Test.LLM
  alias Wardrik.TimeZone
  alias WardrikPolicy.Budget
  alias WardrikPolicy.Spend

  describe "decode/1 and encode/1" do
    test "round-trip, with the defaults filled in" do
      assert {:ok, budget} = Budget.decode(%{"usd" => 5})
      assert budget == %Budget{usd: 5.0, per: :day, timezone: TimeZone.utc(), on_exhausted: :ask}
      assert Budget.grant(budget) == {5_000_000, 0}

      full = %{
        "usd" => 2.5,
        "tokens" => 100_000,
        "per" => "week",
        "timezone" => "Europe/Berlin",
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

      assert {:error, ~s(budget timezone: "Moon/Base" is not a time zone)} =
               Budget.decode(%{"usd" => 1, "timezone" => "Moon/Base"})

      assert {:error, "budget dollars is not a setting" <> _} =
               Budget.decode(%{"usd" => 1, "dollars" => 1})
    end
  end

  test "window/3 names the period a moment falls in, in the budget's time zone" do
    {:ok, berlin} = TimeZone.new("Europe/Berlin")
    now = ~U[2026-09-30 22:30:00Z]

    assert Budget.window(%Budget{usd: 1.0, per: :day}, "t1", now) == "day:2026-09-30"

    assert Budget.window(%Budget{usd: 1.0, per: :day, timezone: berlin}, "t1", now) ==
             "day:2026-10-01"

    assert Budget.window(%Budget{usd: 1.0, per: :month}, "t1", now) == "month:2026-09"

    assert Budget.window(%Budget{usd: 1.0, per: :month, timezone: berlin}, "t1", now) ==
             "month:2026-10"

    assert Budget.window(%Budget{usd: 1.0, per: :week, timezone: berlin}, "t1", now) ==
             "week:2026-W40"
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
        for key <- WardrikStore.keys(Wardrik.Test.store(), :budgets, to_string(agent)),
            do: WardrikStore.delete(Wardrik.Test.store(), :budgets, key)
      end)

      policy = WardrikPolicy.decode!(%{"budget" => %{"usd" => 1.0, "grant" => %{"usd" => 0.5}}})
      hooks = WardrikPolicy.hooks(policy)

      run =
        Run.root(Config.new(), agent,
          hooks: hooks,
          host: Wardrik.Host.new(store: Wardrik.Test.store())
        )

      %{
        budget: List.last(hooks).value,
        run: run,
        request: Request.new(Config.new(), Conversation.new())
      }
    end

    defp costing(usd) do
      %{
        LLM.final_answer("done")
        | usage: %Usage{input_tokens: 10, output_tokens: 5, total_cost: usd}
      }
    end

    defp under(run, policy), do: %{run | hooks: WardrikPolicy.hooks(policy)}

    # The model call `request` makes under `run`, as its hooks decide it.
    defp decide(run, request), do: request |> Pipeline.model(run) |> Pipeline.decide()

    # A model call its hooks let go ahead under `run`, which ended as
    # `outcome`, and which they hear.
    defp spend(run, request, outcome) do
      %{Pipeline.model(request, run) | state: :allowed}
      |> Pipeline.run(&Call.answer(&1, outcome))
    end

    defp approve(waiting, run),
      do: waiting |> Call.approve() |> Call.under(run) |> Hook.approved()

    test "is named for its policy, after the policy's rules" do
      policy = WardrikPolicy.decode!(%{"budget" => %{"usd" => 1.0}}, "careful")

      assert [
               %Hook{name: "careful", module: WardrikPolicy},
               %Hook{name: "careful/budget"} = budget
             ] =
               WardrikPolicy.hooks(policy)

      assert budget.module == Budget
      assert budget.value == %{policy.budget | meter: "careful/budget"}
      assert [%Hook{name: "policy"}] = WardrikPolicy.hooks(WardrikPolicy.decode!(%{}))
    end

    test "admits calls until the period's spend reaches the limit", context do
      %{run: run, request: request} = context

      assert %Call{state: :allowed} = decide(run, request)

      spend(run, request, {:ok, costing(0.6)})
      assert %Call{state: :allowed} = decide(run, request)

      spend(run, request, {:ok, costing(0.6)})

      assert %Call{state: :waiting} = waiting = decide(run, request)

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
      %{budget: budget, run: run, request: request} = context

      spend(run, request, {:ok, costing(1.2)})
      assert %Call{state: :waiting} = waiting = decide(run, request)

      :ok = approve(waiting, run)

      assert %Call{state: :allowed} = decide(run, request)

      assert %Spend{micro_usd: 1_200_000, granted_micro_usd: 500_000} =
               Budget.spent(budget, run)

      assert Budget.spending(budget, run.source.agent_id) == "$1.20 of $1.50 today"
    end

    test "an agent's threads spend from one budget, and a grant frees them all", context do
      %{budget: budget, run: run, request: request} = context
      agent = run.source.agent_id

      thread = fn id ->
        Run.root(Config.new(), Wardrik.Thread.new!(agent, id), hooks: run.hooks)
      end

      one = thread.("C1-1.0")
      two = thread.("C1-2.0")

      spend(one, request, {:ok, costing(0.6)})
      spend(two, request, {:ok, costing(0.6)})

      assert %Call{state: :waiting} = decide(one, request)
      assert %Call{state: :waiting} = waiting = decide(two, request)

      :ok = approve(waiting, two)

      assert %Call{state: :allowed} = decide(one, request)
      assert %Call{state: :allowed} = decide(run, request)
      assert Budget.spending(budget, agent) == "$1.20 of $1.50 today"

      other = Run.root(Config.new(), %{agent | name: "other"}, hooks: run.hooks)
      assert %Call{state: :allowed} = decide(other, request)
      assert Budget.spent(budget, other) == %Spend{}
    end

    test "a budget that denies ends the turn instead of parking", context do
      %{run: run, request: request} = context

      run =
        under(
          run,
          WardrikPolicy.decode!(%{"budget" => %{"usd" => 1.0, "on_exhausted" => "deny"}})
        )

      spend(run, request, {:ok, costing(1.0)})

      assert %Call{
               state: :denied,
               denied: %{reason: "This agent has spent $1.00 of $1.00 today."}
             } =
               decide(run, request)
    end

    test "a call that failed before it was answered spends nothing", context do
      %{budget: budget, run: run, request: request} = context

      spend(run, request, {:error, :timeout})

      assert %Spend{micro_usd: 0, tokens: 0} = Budget.spent(budget, run)
    end

    test "a call that ended without reporting what it used is counted as estimated", context do
      %{budget: budget, run: run} = context
      model = {:anthropic, model: "claude-sonnet-5"}
      streamed = String.duplicate("a", 400)

      request =
        Request.new(
          Config.new(model_spec: model, system: String.duplicate("s", 400)),
          Conversation.new([User.new(String.duplicate("q", 4000))])
        )

      input = Tokens.request(request)
      output = Tokens.text(streamed)
      usage = %Usage{input_tokens: input, output_tokens: output}
      each = Budget.micro(Cost.of(Wardrik.Host.llm(run.host), model, usage))

      spend(run, request, {:interrupted, streamed})
      spend(run, request, {:error, :closed, streamed})
      spend(run, request, {:ok, LLM.final_answer(streamed)})

      assert input == 1100 and output == 100 and each > 0
      assert %Spend{micro_usd: micro_usd, tokens: tokens} = Budget.spent(budget, run)
      assert tokens == 3 * (input + output)
      assert micro_usd == 3 * each
    end

    test "counts a call once against each budget, and grants to one alone", context do
      %{run: run, request: request} = context
      own = WardrikPolicy.decode!(%{"budget" => %{"usd" => 0.01}}, "own")
      ceiling = WardrikPolicy.decode!(%{"budget" => %{"usd" => 1.0}}, "ceiling/team")
      hooks = WardrikPolicy.hooks(ceiling) ++ WardrikPolicy.hooks(own)
      run = %{run | hooks: hooks}
      [ceiling_budget, own_budget] = for %Hook{module: Budget, value: b} <- hooks, do: b

      spend(run, request, {:ok, costing(0.02)})

      assert %Spend{micro_usd: 20_000} = Budget.spent(ceiling_budget, run)
      assert %Spend{micro_usd: 20_000} = Budget.spent(own_budget, run)

      assert %Call{state: :waiting} = waiting = decide(run, request)
      :ok = approve(waiting, run)

      assert %Spend{granted_micro_usd: granted} = Budget.spent(own_budget, run)
      assert granted > 0

      assert %Spend{granted_micro_usd: 0} = Budget.spent(ceiling_budget, run)
    end

    test "counts a model call at the cost the call carries, as its event does", context do
      %{budget: budget, run: run, request: request} = context

      made = spend(run, request, {:ok, costing(0.0123)})

      assert made.cost == %{micro_usd: 12_300, source: :provider}
      assert %Spend{micro_usd: 12_300} = Budget.spent(budget, run)
    end

    test "counts a tool call, failed or not, at the price its tool reported or the config lists",
         context do
      %{budget: budget, run: run} = context

      search =
        Wardrik.Tool.new!(
          name: "search",
          description: "Searches, at a price.",
          schema: [],
          run: fn _input, _context -> Wardrik.Tool.Result.ok(%{"hits" => 1}, cost: 0.004) end
        )

      free =
        Wardrik.Tool.new!(
          name: "free",
          description: "Costs nothing it knows of.",
          schema: [],
          run: fn _input, _context -> Wardrik.Tool.Result.ok(%{}) end
        )

      declined =
        Wardrik.Tool.new!(
          name: "charge",
          description: "Fails, and is charged.",
          schema: [],
          run: fn _input, _context -> {:error, "Declined.", cost: 0.25} end
        )

      listed =
        Wardrik.Tool.new!(
          name: "lookup",
          description: "Says nothing of cost; the config lists it.",
          schema: [],
          run: fn _input, _context -> {:error, "Not found."} end
        )

      config =
        Config.new(tools: [search, free, declined, listed], tool_prices: %{"lookup" => 0.1})

      run = %{run | config: config}

      for {id, name} <- [
            {"c1", "search"},
            {"c2", "free"},
            {"c3", "search"},
            {"c4", "charge"},
            {"c5", "lookup"}
          ] do
        %{Call.tool(%{id: id, name: name, arguments: %{}}, run) | state: :allowed}
        |> Pipeline.run()
      end

      assert %Spend{micro_usd: 358_000, tokens: 0} = Budget.spent(budget, run)
    end

    test "a budget in dollars refuses a model the host's client cannot price", context do
      %{run: run} = context

      request = Request.new(Config.new(model_spec: "nowhere:no-such-model"), Conversation.new())

      assert %Call{state: :denied, denied: %{reason: "This agent's budget is in dollars" <> _}} =
               decide(run, request)

      in_tokens = under(run, WardrikPolicy.decode!(%{"budget" => %{"tokens" => 1000}}))
      assert %Call{state: :allowed} = decide(in_tokens, request)
    end

    test "a token limit governs a call that costs nothing in dollars", context do
      %{run: run, request: request} = context
      run = under(run, WardrikPolicy.decode!(%{"budget" => %{"tokens" => 20}}))

      spend(run, request, {:ok, costing(0.0)})
      assert %Call{state: :allowed} = decide(run, request)

      spend(run, request, {:ok, costing(0.0)})

      assert %Call{state: :waiting} = waiting = decide(run, request)

      assert Call.prompt(waiting) ==
               "This agent has spent 30 of 20 tokens today. Approve to allow 20 tokens more."

      :ok = approve(waiting, run)
      assert %Call{state: :allowed} = decide(run, request)
    end

    test "allows every tool call", context do
      %{run: run} = context
      call = Call.tool(%{id: "call_1", name: "deploy", arguments: %{}}, run)

      assert %Call{state: :allowed} = Hook.check(call)
    end

    test "approving a tool call grants nothing, since no budget asked about it", context do
      %{budget: budget, run: run} = context
      call = Call.tool(%{id: "call_1", name: "deploy", arguments: %{}}, run)

      assert :ok = Budget.approved(call, nil, budget)
    end

    test "hearing what a tool call did spends nothing", context do
      %{budget: budget, run: run} = context
      call = Call.tool(%{id: "call_1", name: "deploy", arguments: %{}}, run)

      assert :ok = Budget.settle(Call.answer(call, {:ok, "deployed"}), budget)
      assert %Spend{micro_usd: 0, tokens: 0} = Budget.spent(budget, run)
    end

    test "a grant the meter cannot record is logged, and the approval stands", context do
      %{budget: budget, run: run, request: request} = context
      stub(WardrikPolicy.Meter, :grant, fn _key, _usd, _tokens -> {:error, :no_capacity} end)

      log = capture_log(fn -> Budget.approved(Call.model(request, run), "day:x", budget) end)

      assert log =~ "granted more budget that was not recorded"
    end

    test "calls settling at once each count, with nothing retried", context do
      %{budget: budget, run: run, request: request} = context

      1..200
      |> Task.async_stream(
        fn _ -> spend(run, request, {:ok, costing(0.01)}) end,
        max_concurrency: 200
      )
      |> Stream.run()

      assert %Spend{tokens: 3000, micro_usd: 2_000_000} = Budget.spent(budget, run)
    end

    test "a budget whose meter cannot be read refuses the call", context do
      %{run: run, request: request} = context

      stub(WardrikPolicy.Meter, :read, fn _key -> {:error, {:meter_unavailable, :no_capacity}} end)

      assert %Call{
               state: :denied,
               denied: %{reason: "This agent's budget could not be read" <> _}
             } =
               decide(run, request)
    end
  end

  test "a budget is part of a policy's written form" do
    written = %{
      "budget" => %{
        "usd" => 5.0,
        "tokens" => 1000,
        "per" => "day",
        "timezone" => "Asia/Tokyo",
        "on_exhausted" => "ask"
      },
      "default" => "allow"
    }

    assert written |> WardrikPolicy.decode!() |> WardrikPolicy.encode() == written
  end
end
