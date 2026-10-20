defmodule Wardrik.Agent.ActivityTest do
  use ExUnit.Case, async: true

  alias Wardrik.Agent.Activity
  alias Wardrik.Agent.Message
  alias Wardrik.Bus
  alias Wardrik.Bus.Source

  @source Source.root(Wardrik.AgentID.parse!("test/active"), name: "turn")

  @asked %Bus.TurnStarted{messages: [Message.new("go")]}
  @model %Bus.ModelStarted{message_id: "m0", model_spec: "x:y", decided_by: nil}
  @retry %Bus.ModelRetrying{
    message_id: "m0",
    attempt: 2,
    attempts: 6,
    wait_ms: 900,
    reason: :timeout
  }
  @span %Bus.SpanStarted{name: "compacting history"}
  @parked %Bus.TurnParked{
    calls: [{%{id: "c1", name: "send_email", arguments: %{}}, "Send it?"}]
  }
  @queued %Bus.MessageQueued{message: Message.new("and this")}

  defp started(id, name),
    do: %Bus.ToolStarted{
      call_id: id,
      name: name,
      arguments: %{},
      idempotency_key: id,
      decided_by: nil
    }

  defp finished(id, name),
    do: %Bus.ToolFinished{
      call_id: id,
      name: name,
      result: {:ok, "hit"},
      served_by: nil,
      cost: nil
    }

  defp fold(payloads) do
    payloads
    |> Enum.with_index(1)
    |> Enum.reduce(%Activity{doing: :idle, since: 0}, fn {payload, at}, activity ->
      Activity.fold(activity, %Bus.Event{source: @source, payload: payload, at: at})
    end)
  end

  test "the last event that says what it is doing wins, and a turn ending sets it idle" do
    search = started("c1", "web_search")
    fetch = started("c2", "fetch_page")
    done = finished("c2", "fetch_page")

    for {payloads, doing, since} <- [
          {[], :idle, 0},
          {[@asked], @asked, 1},
          {[@asked, @model], @model, 2},
          {[@asked, @model, %Bus.Result{text: "Hel"}, %Bus.Thinking{text: "hm"}], @model, 2},
          {[@model, @retry], @retry, 2},
          {[@asked, @span], @span, 2},
          {[@span, %Bus.SpanFinished{outcome: :ok, duration_ms: 5}], @span, 1},
          {[@model, search], [search], 2},
          {[@model, search, fetch], [search, fetch], 3},
          {[search, fetch, finished("c1", "web_search")], [fetch], 3},
          {[search, fetch, finished("c1", "web_search"), done], done, 4},
          {[search, finished("c9", "other")], [search], 1},
          {[search, @span, done], done, 3},
          {[search, @parked], @parked, 2},
          {[@model, %Bus.TurnFinished{messages: []}], :idle, 2},
          {[@model, %Bus.TurnFailed{reason: :boom}], :idle, 2},
          {[@parked, %Bus.TurnResumed{decisions: %{}}], %Bus.TurnResumed{decisions: %{}}, 2}
        ] do
      assert %Activity{doing: ^doing, since: ^since} = fold(payloads)
    end
  end

  test "counts the messages waiting, from queued to taken or dropped" do
    stopped = %Bus.TurnInterrupted{
      stats: %{dropped: 2, kept: 0, resolution: :idle, elapsed_ms: 0}
    }

    for {payloads, pending, since} <- [
          {[@queued], 1, 0},
          {[@queued, @queued, @asked], 1, 3},
          {[@queued, @queued, @queued, stopped], 1, 0},
          {[@asked], 0, 1},
          {[@model, @queued], 1, 1}
        ] do
      assert %Activity{pending: ^pending, since: ^since} = fold(payloads)
    end
  end
end
