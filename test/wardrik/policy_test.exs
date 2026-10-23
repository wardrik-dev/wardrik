defmodule Wardrik.PolicyTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  setup :set_mimic_global

  setup context do
    store = WardrikStore.ETS.new(name: :"store #{context.test}")

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        store: store,
        policy: [deny: ["inbox"]]
      )

    start_supervised!({WardrikStore, store})
    start_supervised!({Wardrik, wardrik})

    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
    %{wardrik: wardrik, scope: owner(wardrik)}
  end

  defp answers(responses) do
    {:ok, queue} = Agent.start_link(fn -> responses end)

    stub(ReqLLM, :stream_text, fn _model, _messages, _opts ->
      {:ok, Agent.get_and_update(queue, fn [next | rest] -> {next, rest} end)}
    end)
  end

  defp start_books(wardrik, policy) do
    {:ok, _agent} =
      Wardrik.start_agent(wardrik,
        agent_id: "acme/books",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [Wardrik.Test.Tools],
        policy: policy
      )
  end

  test "asks a person where the agent's policy says to", %{wardrik: wardrik, scope: scope} do
    answers([calling([call("call_1", "echo", %{"text" => "hi"})]), answer("Done.")])
    start_books(wardrik, ask: %{"echo" => "Echo this?"})

    Wardrik.Agent.ask(scope, "acme/books", "Echo hi")
    until("wardrik.run.interrupted")

    assert {:ok,
            %Wardrik.Agent{interrupts: [%Wardrik.Interrupt{id: "call_1", message: "Echo this?"}]}} =
             Wardrik.Agent.read(scope, "acme/books")

    assert {:ok, [%Wardrik.Decision{id: "call_1", decision: :approved}]} =
             Wardrik.Agent.approve(scope, "acme/books", "call_1")

    assert %{"data" => %{"status" => "ok"}} = until("wardrik.tool_call.completed")
    until("wardrik.run.completed")
  end

  test "refuses what the deployment denies, though the agent allows it", %{
    wardrik: wardrik,
    scope: scope
  } do
    answers([calling([call("call_1", "inbox", %{})]), answer("Done.")])
    start_books(wardrik, allow: ["inbox"])

    Wardrik.Agent.ask(scope, "acme/books", "Read my mail")

    assert %{"data" => %{"status" => "error"}} = until("wardrik.tool_call.completed")
    until("wardrik.run.completed")
  end

  test "takes a policy built already" do
    policy = WardrikPolicy.new!(deny: ["shell/*"])

    assert %Wardrik{policy: ^policy} =
             Wardrik.new(name: MyApp.Wardrik, store: :store, policy: policy)
  end
end
