defmodule Wardrik.SinkTest do
  use ExUnit.Case, async: false

  import Wardrik.EventLog.Test.Events

  defmodule Told do
    @behaviour Wardrik.Sink

    @impl true
    def handle_event(event, opts), do: send(opts[:test], {:sunk, event})
  end

  setup context do
    store = Wardrik.Store.ETS.new(name: :"store #{context.test}")
    events = :"events #{context.test}"
    start_supervised!({Wardrik.Store, store})

    start_supervised!(
      {Wardrik.EventLog, name: events, store: store, sinks: [{Told, test: self()}]}
    )

    %{events: events}
  end

  test "hands each kept event over with its sequence, agents' and the audit's", %{events: events} do
    stopped(events, {"agt_1", "C1"})

    assert_received {:sunk,
                     %Wardrik.Event{
                       type: "wardrik.agent.stopped",
                       agent: "agt_1",
                       conversation: "C1",
                       sequence: "000000000001"
                     }}

    :ok = Wardrik.EventLog.record(events, {"agent.forgotten", "agents/agt_1", %{}})

    assert_received {:sunk,
                     %Wardrik.Event{type: "wardrik.agent.forgotten", sequence: "000000000001"}}
  end

  test "hands over no live event", %{events: events} do
    emit(events, "agt_1", [:message, :delta], %{
      kind: :content,
      span: WardrikCore.Span.root(),
      text: "Hi"
    })

    refute_received {:sunk, _event}
  end
end
