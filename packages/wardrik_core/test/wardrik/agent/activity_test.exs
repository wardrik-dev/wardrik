defmodule Wardrik.Agent.ActivityTest do
  use ExUnit.Case, async: true

  alias Wardrik.Agent.Activity
  alias Wardrik.Agent.Message
  alias Wardrik.Event
  alias Wardrik.Event.Source

  @source Source.root(Wardrik.AgentID.parse!("test/active"), name: "turn")

  @asked %Event.TurnStarted{messages: [Message.new("go")]}
  @model %Event.ModelStarted{message_id: "m0", model_spec: "x:y", decided_by: nil}
  @retry %Event.ModelRetrying{
    message_id: "m0",
    attempt: 2,
    attempts: 6,
    wait_ms: 900,
    reason: :timeout
  }
  @span %Event.SpanStarted{name: "compacting history"}
  @parked %Event.TurnParked{
    calls: [{%{id: "c1", name: "send_email", arguments: %{}}, "Send it?"}]
  }
  @queued %Event.MessageQueued{message: Message.new("and this")}

  defp started(id, name),
    do: %Event.ToolStarted{
      call_id: id,
      name: name,
      arguments: %{},
      idempotency_key: id,
      decided_by: nil
    }

  defp finished(id, name),
    do: %Event.ToolFinished{
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
      Activity.fold(activity, %Event{source: @source, payload: payload, at: at})
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
          {[@asked, @model, %Event.Result{text: "Hel"}, %Event.Thinking{text: "hm"}], @model, 2},
          {[@model, @retry], @retry, 2},
          {[@asked, @span], @span, 2},
          {[@span, %Event.SpanFinished{outcome: :ok, duration_ms: 5}], @span, 1},
          {[@model, search], [search], 2},
          {[@model, search, fetch], [search, fetch], 3},
          {[search, fetch, finished("c1", "web_search")], [fetch], 3},
          {[search, fetch, finished("c1", "web_search"), done], done, 4},
          {[search, finished("c9", "other")], [search], 1},
          {[search, @span, done], done, 3},
          {[search, @parked], @parked, 2},
          {[@model, %Event.TurnFinished{messages: []}], :idle, 2},
          {[@model, %Event.TurnFailed{reason: :boom}], :idle, 2},
          {[@parked, %Event.TurnResumed{decisions: %{}}], %Event.TurnResumed{decisions: %{}}, 2}
        ] do
      assert %Activity{doing: ^doing, since: ^since} = fold(payloads)
    end
  end

  test "counts the messages waiting, from queued to taken or dropped" do
    stopped = %Event.TurnInterrupted{
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
