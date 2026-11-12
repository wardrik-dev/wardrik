defmodule Wardrik.ViewsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  alias Wardrik.Views.Runs
  alias Wardrik.Views.Timeline

  setup :set_mimic_global
  setup :start_wardrik

  setup %{wardrik: wardrik} do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    stub(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, answer("Nothing.")} end)
    :ok = Wardrik.EventLog.subscribe(Wardrik.events(wardrik), :all)
    start_agent(wardrik, "acme/triage")
    scope = owner(wardrik)
    {:ok, _message} = Wardrik.Agent.ask(scope, "acme/triage", content: "Hi", id: "msg_1")
    until("wardrik.run.completed")
    %{scope: scope}
  end

  test "folds an agent's events, as structs or as JSON, into its conversation", %{scope: scope} do
    {:ok, %Wardrik.Page{events: events}} = Wardrik.Agent.events(scope, "acme/triage")
    {:ok, %{"events" => json}} = Wardrik.run(scope, "agent.events", %{"agent" => "acme/triage"})

    timeline = Timeline.fold(events)
    assert Timeline.items(timeline) == json |> Timeline.fold() |> Timeline.items()

    assert [%{kind: :user, text: "Hi"}, %{kind: :run, status: :completed} = run] =
             Timeline.items(timeline)

    assert Timeline.current_run(timeline) == run
    refute Timeline.running?(timeline)
    assert Timeline.interrupts(timeline) == []
  end

  test "folds an agent's runs, with their events where asked", %{scope: scope} do
    {:ok, %Wardrik.Page{events: events}} = Wardrik.Agent.events(scope, "acme/triage")

    runs = Runs.fold(events, events: true)

    assert [%{status: :completed, events: [%{"type" => "wardrik.run.started"} | _rest]} = run] =
             Runs.runs(runs)

    assert is_integer(Runs.duration_ms(run))
    assert %{runs: 1, failed: 0} = Runs.totals(runs)
    assert %{runs: 2} = Runs.sum([Runs.totals(runs), Runs.totals(runs)])
  end
end
