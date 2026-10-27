defmodule Wardrik.SpendingTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  @model "anthropic:claude-haiku-4-5"

  setup :set_mimic_global

  setup context do
    store = Wardrik.Test.Store.new(:"store #{context.test}")

    wardrik =
      Wardrik.new(
        name: :"wardrik #{context.test}",
        store: store,
        capabilities: [priced: Wardrik.Test.Priced]
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

  defp used(response, input, output),
    do: %{response | usage: %{input_tokens: input, output_tokens: output}}

  test "counts what each model call and tool call spent today", %{scope: scope} do
    answers([
      used(calling([call("call_1", "search", %{})]), 100, 20),
      used(answer("Done."), 50, 10)
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

    assert DateTime.compare(parsed(hourly), parsed(daily)) == :lt

    assert %{"agents" => [%{"next_run" => ^hourly, "spent_today" => %{"tokens" => 0}}]} =
             run!(scope, "agents.list", %{})

    assert {:ok, %Wardrik.Agent{next_run: %DateTime{}}} = Wardrik.Agent.read(scope, "acme/scout")
  end

  defp parsed(text) do
    {:ok, at, _offset} = DateTime.from_iso8601(text)
    at
  end
end
