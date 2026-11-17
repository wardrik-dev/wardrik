defmodule Wardrik.SpendingTest do
  use ExUnit.Case, async: true

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @model "anthropic:claude-haiku-4-5"

  setup context do
    {fake, endpoints} = Wardrik.Test.Model.start()
    store_name = :"store #{context.test}"
    store = Wardrik.Test.Store.new(store_name)

    wardrik =
      Wardrik.new(
        endpoints: endpoints,
        authorizer: {Wardrik.Test.Allow, []},
        resolver: {Wardrik.Test.Owned, :"wardrik #{context.test}"},
        name: :"wardrik #{context.test}",
        store: store,
        capabilities: [priced: Wardrik.Test.Priced, delegating: Wardrik.Test.Delegating]
      )

    start_supervised!({Wardrik.Store, store})
    start_supervised!({Wardrik, wardrik})
    event_log = Wardrik.events(wardrik)
    :ok = Wardrik.EventLog.subscribe(event_log, :all)
    %{fake: fake, wardrik: wardrik, scope: owner(wardrik)}
  end

  defp answers(fake, responses), do: Wardrik.Testing.Model.answer(fake, responses)

  defp put_usage(response, input, output),
    do: %{response | usage: %{input_tokens: input, output_tokens: output}}

  test "counts what each model call and tool call spent today", %{fake: fake, scope: scope} do
    answers(fake, [
      put_usage(calling([call("call_1", "search", %{})]), 100, 20),
      put_usage(answer("Done."), 50, 10)
    ])

    run!(scope, "agent.define", %{
      "agent" => "acme/scout",
      "model" => @model,
      "tools" => ["priced"]
    })

    run!(scope, "agent.ask", %{"agent" => "acme/scout", "content" => "Look"})
    until("wardrik.run.completed")

    assert %{"agents" => [%{"id" => "acme/scout", "spent_today" => spent}]} =
             run!(scope, "agents.list", %{})

    assert spent == %{"tokens" => 180, "usd" => 0.01}
    assert %{"spent_today" => ^spent} = run!(scope, "agent.read", %{"agent" => "acme/scout"})
  end

  test "counts what a subagent spent once, as the call that ran it", %{fake: fake, scope: scope} do
    answers(fake, [
      put_usage(calling([call("call_1", "delegate", %{})]), 100, 20),
      put_usage(answer("Done it."), 40, 8),
      put_usage(answer("Done."), 50, 10)
    ])

    run!(scope, "agent.define", %{
      "agent" => "acme/scout",
      "model" => @model,
      "tools" => ["delegating"]
    })

    run!(scope, "agent.ask", %{"agent" => "acme/scout", "content" => "Delegate"})
    until("wardrik.subagent.completed")
    until("wardrik.run.completed")

    assert %{"spent_today" => %{"tokens" => 228}} =
             run!(scope, "agent.read", %{"agent" => "acme/scout"})
  end

  test "says when each trigger runs next, and the soonest", %{scope: scope} do
    triggers = [
      %{"name" => "hourly", "every" => "1h", "prompt" => "Look."},
      %{"name" => "daily", "every" => "1d", "prompt" => "Look again."}
    ]

    run!(scope, "agent.define", %{
      "agent" => "acme/scout",
      "model" => @model,
      "triggers" => triggers
    })

    assert %{"next_runs" => %{"hourly" => hourly, "daily" => daily}} =
             run!(scope, "agent.definition", %{"agent" => "acme/scout"})

    next_hourly = parse(hourly)
    assert DateTime.compare(next_hourly, parse(daily)) == :lt

    assert %{"agents" => [%{"next_run" => ^hourly, "spent_today" => %{"tokens" => 0}}]} =
             run!(scope, "agents.list", %{})

    assert {:ok, %Wardrik.Agent{next_run: %DateTime{}}} = Wardrik.Agent.read(scope, "acme/scout")
  end

  defp parse(text) do
    {:ok, at, _offset} = DateTime.from_iso8601(text)
    at
  end
end
