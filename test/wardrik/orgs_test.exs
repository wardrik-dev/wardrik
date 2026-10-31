defmodule Wardrik.Test.Orgs do
  @moduledoc "Orgs whose settings a test sets, by org, in an `Agent`."
  @behaviour Wardrik.Orgs

  @impl true
  def settings(org, agent), do: Agent.get(agent, &Map.get(&1, org, {:ok, %Wardrik.OrgSettings{}}))
end

defmodule Wardrik.OrgsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.OrgSettings
  alias Wardrik.Statement

  @model "anthropic:claude-haiku-4-5"

  setup :set_mimic_global

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")
    orgs = start_supervised!({Agent, fn -> %{} end})

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        store: store,
        orgs: {Wardrik.Test.Orgs, orgs},
        capabilities: [priced: Wardrik.Test.Priced],
        policies: [base: []]
      )

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    %{wardrik: wardrik, orgs: orgs, scope: owner(wardrik)}
  end

  defp set(orgs, org, settings), do: Agent.update(orgs, &Map.put(&1, org, settings))

  defp answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  defp used(response, input, output),
    do: %{response | usage: %{input_tokens: input, output_tokens: output}}

  defp define(scope, id, fields \\ %{}),
    do: Wardrik.run(scope, "agent.define", Map.merge(%{"agent" => id, "model" => @model}, fields))

  defp ask(scope, id), do: run!(scope, "agent.ask", %{"agent" => id, "content" => "Look"})

  test "an agent's or owner's org is read through Wardrik.Owners" do
    assert Enum.map(
             ["acme/@maria/assistant", "acme/triage/C1", "acme/@maria", "acme", "deployment"],
             &Wardrik.Orgs.org/1
           ) == ["acme", "acme", "acme", "acme", "deployment"]

    assert Wardrik.Orgs.org("slack:T0123/U024BE7LH") == "slack:T0123/U024BE7LH"
  end

  describe "an org's settings" do
    test "give its definitions its defaults, and policies they may name", %{
      scope: scope,
      orgs: orgs
    } do
      set(
        orgs,
        "acme",
        {:ok,
         %OrgSettings{defaults: %{model: @model}, policies: %{"careful" => [deny: ["search"]]}}}
      )

      answers([calling([call("call_1", "search", %{})]), answer("Done.")])
      fields = %{"agent" => "acme/scout", "tools" => ["priced"], "policy" => "careful"}
      run!(scope, "agent.define", fields)
      ask(scope, "acme/scout")

      until("wardrik.tool_call.denied")
      until("wardrik.run.completed")

      assert refused(scope, "agent.define", %{fields | "agent" => "globex/scout"}) ==
               :invalid_request
    end

    test "hold its agents to its policy", %{scope: scope, orgs: orgs} do
      set(orgs, "acme", {:ok, %OrgSettings{policy: %{"deny" => ["search"]}}})
      answers([calling([call("call_1", "search", %{})]), answer("Done.")])

      {:ok, _agent} = define(scope, "acme/scout", %{"tools" => ["priced"]})
      ask(scope, "acme/scout")

      until("wardrik.tool_call.denied")
      until("wardrik.run.completed")
    end

    test "can't name a policy for one of the deployment's", %{scope: scope, orgs: orgs} do
      set(orgs, "acme", {:ok, %OrgSettings{policies: %{base: [deny: ["*"]]}}})

      assert {:error, %Wardrik.Error{type: :invalid_request, message: message}} =
               define(scope, "acme/scout")

      assert message =~ "acme's settings don't read: its policy base has the name"
    end

    test "keep its agents from starting where they don't read", %{scope: scope, orgs: orgs} do
      set(orgs, "acme", {:error, :down})

      assert {:error, %Wardrik.Error{type: :unavailable, message: message}} =
               define(scope, "acme/scout")

      assert message == "acme's settings didn't read: :down"
    end

    test "hold its agents to each of its policies in turn", %{scope: scope, orgs: orgs} do
      set(
        orgs,
        "acme",
        {:ok, %OrgSettings{policy: [%{"default" => "allow"}, %{"deny" => ["search"]}]}}
      )

      answers([calling([call("call_1", "search", %{})]), answer("Done.")])

      {:ok, _agent} = define(scope, "acme/scout", %{"tools" => ["priced"]})
      ask(scope, "acme/scout")

      until("wardrik.tool_call.denied")
      until("wardrik.run.completed")
    end

    test "refuse what an org there's no such thing as would keep", %{scope: scope, orgs: orgs} do
      set(orgs, "globex", {:error, Wardrik.Error.new(:not_found, "There's no org globex here.")})
      no_org = %Wardrik.Error{type: :not_found, message: "There's no org globex here."}

      assert {:error, ^no_org} = define(scope, "globex/scout")

      assert {:error, ^no_org} =
               Wardrik.run(scope, "secrets.put", %{
                 "owner" => "globex/@ada",
                 "name" => "KEY",
                 "value" => "v"
               })

      assert {:error, ^no_org} =
               Wardrik.run(scope, "tokens.create", %{
                 "name" => "ci",
                 "resources" => ["acme/agent/*", "globex/agent/*"],
                 "roles" => ["reader"]
               })

      assert %{"secret" => _secret} =
               run!(scope, "tokens.create", %{
                 "name" => "ci",
                 "resources" => ["*/agent/*"],
                 "roles" => ["reader"]
               })
    end

    test "reach its awake agents as they're refreshed", %{
      wardrik: wardrik,
      scope: scope,
      orgs: orgs
    } do
      {:ok, _agent} = define(scope, "acme/scout")
      assert Wardrik.refresh(wardrik, org: "acme") == []

      set(orgs, "acme", {:ok, %OrgSettings{ceilings: %{"cap" => [tokens: 100, per: :turn]}}})

      assert Wardrik.refresh(wardrik, org: "acme") == [
               "acme/scout: acme's settings don't read: its ceiling cap: a ceiling isn't per turn."
             ]

      assert Wardrik.refresh(wardrik, org: "globex") == []
    end
  end

  describe "a ceiling" do
    setup %{wardrik: wardrik} do
      test = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach(
        id,
        [:wardrik, :ceiling, :reached],
        fn name, measurements, metadata, _config ->
          send(test, {name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
      %{approver: approver(wardrik)}
    end

    defp approver(wardrik),
      do:
        Wardrik.as(wardrik, "acme/@sam", [
          Statement.new(roles: [:approver, :reader], resources: ["acme/agent/*"])
        ])

    defp spend_it(scope) do
      {:ok, _agent} = define(scope, "acme/first")
      ask(scope, "acme/first")
      until("wardrik.run.completed")
      {:ok, _agent} = define(scope, "acme/second")
      ask(scope, "acme/second")
    end

    test "asks once the org's agents have spent it together, and an org owner approves more", %{
      wardrik: wardrik,
      scope: scope,
      orgs: orgs,
      approver: approver
    } do
      set(orgs, "acme", {:ok, %OrgSettings{ceilings: %{"cap" => [tokens: 100]}}})
      answers([used(answer("Done."), 80, 40), answer("Done too.")])
      spend_it(scope)

      assert_receive {[:wardrik, :ceiling, :reached], _measurements,
                      %{agent_id: "acme/first", ceiling: "cap", message: message}}

      assert message ==
               "acme's agents have used 120 of 100 tokens today. Approve to allow 100 more."

      assert %{"data" => %{"interrupts" => [%{"id" => "model", "reason" => "ceiling_approval"}]}} =
               until("wardrik.run.interrupted")

      assert {:ok, [%Wardrik.Interrupt{reason: :ceiling_approval, agent_id: "acme/second"}]} =
               Wardrik.Interrupts.list(scope)

      approval = %{"agent" => "acme/second", "interrupt" => "model"}
      assert refused(approver, "agent.approve", approval) == :forbidden

      run!(scope, "agent.approve", approval)
      until("wardrik.run.completed")

      assert {:ok, %{"cap" => %{spent: %{tokens: 120}, granted: %{tokens: 120}}}} =
               Wardrik.Orgs.spent(wardrik, "acme")
    end

    test "says what the org's agents have spent against each, to those who may read it", %{
      wardrik: wardrik,
      scope: scope,
      orgs: orgs,
      approver: approver
    } do
      ceilings = %{"cap" => [tokens: 100, per: :week], "plan" => [usd: 20.0, per: :total]}
      set(orgs, "acme", {:ok, %OrgSettings{ceilings: ceilings}})
      answers([used(answer("Done."), 30, 10)])
      {:ok, _agent} = define(scope, "acme/first")
      ask(scope, "acme/first")
      until("wardrik.run.completed")

      assert %{"ceilings" => [cap, plan]} = run!(scope, "ceilings.list", %{"owner" => "acme"})

      assert %{
               "ceiling" => "cap",
               "per" => "week",
               "on_exhausted" => "ask",
               "limit" => %{"tokens" => 100},
               "spent" => %{"tokens" => 40},
               "granted" => %{},
               "starts_over" => _monday
             } = cap

      refute Map.has_key?(plan, "starts_over")

      reader =
        Wardrik.as(wardrik, "acme/@ana", [Statement.new(roles: [:reader], resources: ["acme/*"])])

      assert {:ok,
              [%Wardrik.Spend{ceiling: "cap", per: :week, starts_over: %Date{}} = spend, _plan]} =
               Wardrik.Ceilings.list(reader, owner: "acme")

      assert spend.limit == %Wardrik.Amount{tokens: 100}
      assert refused(approver, "ceilings.list", %{"owner" => "acme"}) == :not_found
      assert refused(scope, "ceilings.list", %{"owner" => "acme/@maria"}) == :invalid_request
      assert run!(scope, "ceilings.list", %{"owner" => "globex"}) == %{"ceilings" => []}
    end

    test "refuses past it where it denies", %{scope: scope, orgs: orgs} do
      set(
        orgs,
        "acme",
        {:ok, %OrgSettings{ceilings: %{"cap" => [tokens: 100, on_exhausted: :deny]}}}
      )

      answers([used(answer("Done."), 80, 40)])
      {:ok, _agent} = define(scope, "acme/first")
      ask(scope, "acme/first")
      until("wardrik.run.completed")
      {:ok, _agent} = define(scope, "acme/second")

      assert {:error,
              %Wardrik.Error{
                message: "The run failed: acme's agents have used 120 of 100 tokens today."
              }} = Wardrik.Agent.reply(scope, "acme/second", "Go")
    end

    test "lets work carry on where it continues, and says it was reached", %{
      wardrik: wardrik,
      scope: scope,
      orgs: orgs
    } do
      ceilings = %{"watch" => %{"tokens" => 100, "per" => "month", "on_exhausted" => "continue"}}
      set(orgs, "acme", {:ok, %OrgSettings{ceilings: ceilings}})
      answers([used(answer("Done."), 80, 40), used(answer("Done too."), 10, 5)])
      spend_it(scope)

      until("wardrik.run.completed")
      assert_receive {[:wardrik, :ceiling, :reached], _measurements, %{on_exhausted: :continue}}
      refute_received {[:wardrik, :ceiling, :reached], _measurements, _metadata}

      assert {:ok, %{"watch" => %{spent: %{tokens: 135}, starts_over: %Date{day: 1}}}} =
               Wardrik.Orgs.spent(wardrik, "acme")
    end
  end
end
