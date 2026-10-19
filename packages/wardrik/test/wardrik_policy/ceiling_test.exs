defmodule WardrikPolicy.CeilingTest do
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Call
  alias Wardrik.Call.Pipeline
  alias Wardrik.Hook
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Request
  alias Wardrik.Run
  alias Wardrik.Test.LLM
  alias WardrikPolicy.Budget
  alias WardrikPolicy.Ceiling
  alias WardrikPolicy.Spend

  setup do
    org = "ceiling-#{System.unique_integer([:positive])}"
    other = org <> "-other"

    on_exit(fn ->
      for prefix <- [org, other],
          key <- WardrikStore.keys(Wardrik.Test.store(), :budgets, prefix),
          do: WardrikStore.delete(Wardrik.Test.store(), :budgets, key)
    end)

    team =
      WardrikPolicy.decode!(
        %{"budget" => %{"usd" => 1.0, "grant" => %{"usd" => 0.5}}},
        "orgs/#{org}/team"
      )

    %{
      org: org,
      other: other,
      team: team,
      request: Request.new(Config.new(), Wardrik.Conversation.new())
    }
  end

  defp agent(org, name, hooks),
    do: Run.root(Config.new(), AgentID.parse!("#{org}/#{name}"), hooks: hooks)

  defp costing(usd),
    do: %{
      LLM.final_answer("done")
      | usage: %Wardrik.LLM.Usage{input_tokens: 10, output_tokens: 5, total_cost: usd}
    }

  defp decide(run, request), do: request |> Pipeline.model(run) |> Pipeline.decide()

  defp spend(run, request, usd) do
    %{Pipeline.model(request, run) | state: :allowed}
    |> Pipeline.run(&Call.answer(&1, {:ok, costing(usd)}))
  end

  defp approve(waiting, run),
    do: waiting |> Call.approve() |> Call.under(run) |> Hook.approved()

  test "is the policy's hooks with its budget as the org's", %{org: org, team: team} do
    assert [%Hook{name: "orgs/" <> _, module: WardrikPolicy}, %Hook{module: Ceiling} = hook] =
             WardrikPolicy.ceiling(team, org)

    assert hook.name == "orgs/#{org}/team/budget"
    assert hook.value == Ceiling.new(%{team.budget | meter: "orgs/#{org}/team/budget"}, org)
  end

  test "the org's agents spend from it together, and the next call any of them makes stops",
       %{org: org, team: team, request: request} do
    hooks = WardrikPolicy.ceiling(team, org)
    alpha = agent(org, "alpha", hooks)
    beta = agent(org, "beta", hooks)

    spend(alpha, request, 0.6)
    assert %Call{state: :allowed} = decide(beta, request)

    spend(beta, request, 0.6)

    assert %Call{state: :waiting} = waiting = decide(alpha, request)
    assert Call.prompt(waiting) =~ "#{org}'s agents have spent $1.20 of $1.00 today."
    assert %Call{state: :waiting} = decide(beta, request)

    %Hook{value: ceiling} = List.last(hooks)
    assert %Spend{micro_usd: 1_200_000} = Ceiling.spent(ceiling)

    assert Ceiling.spending(ceiling, alpha.source.agent_id) ==
             "$1.20 of $1.00 today across #{org}"
  end

  test "a user's agents in the org spend from it too", %{org: org, team: team, request: request} do
    hooks = WardrikPolicy.ceiling(team, org)

    spend(agent(org, "alpha", hooks), request, 0.6)
    spend(agent(org, "@jon/assistant", hooks), request, 0.6)

    assert %Call{state: :waiting} = decide(agent(org, "alpha", hooks), request)
  end

  test "approving grants more to every agent of the org", %{
    org: org,
    team: team,
    request: request
  } do
    hooks = WardrikPolicy.ceiling(team, org)
    alpha = agent(org, "alpha", hooks)
    beta = agent(org, "beta", hooks)

    spend(alpha, request, 1.2)
    assert %Call{state: :waiting} = waiting = decide(alpha, request)

    :ok = approve(waiting, alpha)

    assert %Call{state: :allowed} = decide(beta, request)
    %Hook{value: ceiling} = List.last(hooks)
    assert %Spend{granted_micro_usd: 500_000} = Ceiling.spent(ceiling)
  end

  test "another org spends from its own", %{org: org, other: other, team: team, request: request} do
    spend(agent(org, "alpha", WardrikPolicy.ceiling(team, org)), request, 1.2)

    other_hooks = WardrikPolicy.ceiling(team, other)
    assert %Call{state: :allowed} = decide(agent(other, "alpha", other_hooks), request)
  end

  test "an agent's own budget still counts apart, beside the org's",
       %{org: org, team: team, request: request} do
    own = WardrikPolicy.decode!(%{"budget" => %{"usd" => 0.5}}, "own")
    hooks = WardrikPolicy.ceiling(team, org) ++ WardrikPolicy.hooks(own)
    alpha = agent(org, "alpha", hooks)
    beta = agent(org, "beta", hooks)

    spend(alpha, request, 0.6)

    assert %Call{state: :waiting} = waiting = decide(alpha, request)
    assert Call.prompt(waiting) =~ "This agent has spent $0.60 of $0.50 today."
    assert %Call{state: :allowed} = decide(beta, request)

    [%Hook{value: own_budget}] = for %Hook{module: Budget} = hook <- hooks, do: hook
    assert %Spend{micro_usd: 0} = Budget.spent(own_budget, beta)
  end

  test "a ceiling per turn has no one period to read", %{org: org} do
    budget = %Budget{usd: 1.0, per: :turn, meter: "orgs/#{org}/team/budget"}
    ceiling = Ceiling.new(budget, org)

    assert Ceiling.spent(ceiling) == nil
    assert Ceiling.spending(ceiling, AgentID.parse!("#{org}/alpha")) == nil
  end
end
