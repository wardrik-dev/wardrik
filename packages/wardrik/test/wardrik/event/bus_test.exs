defmodule Wardrik.Event.BusTest do
  use ExUnit.Case, async: true

  alias Wardrik.Event
  alias Wardrik.Event.Bus
  alias Wardrik.Event.Source
  alias Wardrik.Test.Fleet

  setup do
    {:ok, agent_id: Fleet.id()}
  end

  defp emit(agent_id, payload), do: agent_id |> Source.root() |> Event.emit(payload)

  test "publish reaches every subscriber and no one else", %{agent_id: agent_id} do
    other_agent = Fleet.id()
    :ok = Bus.subscribe(agent_id)
    :ok = Bus.subscribe(other_agent)

    emit(agent_id, %Event.Result{text: "a"})

    assert_receive %Event{payload: %Event.Result{text: "a"}}
    refute_receive %Event{payload: %Event.Result{text: "b"}}
  end

  test "the published event carries the source it was emitted on", %{agent_id: agent_id} do
    :ok = Bus.subscribe(agent_id)
    source = Source.root(agent_id, name: "turn")

    Event.emit(source, %Event.Result{text: "a"})

    assert_receive %Event{source: ^source, payload: %Event.Result{text: "a"}, at: at}
    assert is_integer(at)
  end

  test "publish with no subscribers is a no-op", %{agent_id: agent_id} do
    assert Bus.subscribers(agent_id) == []
    assert emit(agent_id, %Event.Result{text: "a"}) == :ok
  end

  test "unsubscribe stops delivery", %{agent_id: agent_id} do
    :ok = Bus.subscribe(agent_id)
    :ok = Bus.unsubscribe(agent_id)

    assert Bus.subscribers(agent_id) == []

    emit(agent_id, %Event.Result{text: "a"})
    refute_receive %Event{}
  end

  test "a dead subscriber does not affect the others" do
    agent_id = Fleet.id()
    test_pid = self()
    :ok = Bus.subscribe(agent_id)

    {dead, ref} =
      spawn_monitor(fn ->
        Bus.subscribe(agent_id)
        send(test_pid, :subscribed)
        receive do: (:stop -> :ok)
      end)

    assert_receive :subscribed
    send(dead, :stop)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

    emit(agent_id, %Event.Result{text: "a"})
    assert_receive %Event{payload: %Event.Result{text: "a"}}
  end

  describe "levels" do
    test "activity is what a subscriber gets by default", %{agent_id: agent_id} do
      :ok = Bus.subscribe(agent_id)

      emit(agent_id, %Event.Chunk{chunk: "a"})
      emit(agent_id, %Event.Result{text: "a"})

      assert_receive %Event{payload: %Event.Result{text: "a"}}
      refute_received %Event{payload: %Event.Chunk{chunk: "a"}}
    end

    test "raw takes the provider's records too", %{agent_id: agent_id} do
      :ok = Bus.subscribe(agent_id, level: :raw)

      emit(agent_id, %Event.Chunk{chunk: "a"})
      emit(agent_id, %Event.Result{text: "a"})

      assert_receive %Event{payload: %Event.Chunk{chunk: "a"}}
      assert_receive %Event{payload: %Event.Result{text: "a"}}
    end

    test "each subscriber has its own", %{agent_id: agent_id} do
      test_pid = self()

      spawn_link(fn ->
        Bus.subscribe(agent_id, level: :raw)
        send(test_pid, :ready)
        receive do: (%Event{payload: %Event.Chunk{}} = e -> send(test_pid, {:other, e}))
      end)

      assert_receive :ready
      :ok = Bus.subscribe(agent_id)

      emit(agent_id, %Event.Chunk{chunk: "a"})

      assert_receive {:other, %Event{payload: %Event.Chunk{chunk: "a"}}}
      refute_received %Event{payload: %Event.Chunk{chunk: "a"}}
    end

    test "an unknown level is a mistake worth hearing about", %{agent_id: agent_id} do
      assert_raise ArgumentError, ~r/unknown level :loud/, fn ->
        Bus.subscribe(agent_id, level: :loud)
      end
    end
  end

  test "events are published as telemetry, stamped with the span", %{agent_id: agent_id} do
    handler_id = {__MODULE__, agent_id}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:wardrik, :agent, :tool_started],
        # Filtered: the handler is global, and another async test emitting the
        # same event would otherwise win the race to this mailbox.
        fn name, measurements, metadata, _config ->
          if metadata.agent_id == agent_id do
            send(test_pid, {:telemetry, name, measurements, metadata})
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    source = Source.root(agent_id) |> Source.child()

    Event.emit(source, %Event.ToolStarted{
      call_id: "call_1",
      name: "echo",
      arguments: %{},
      idempotency_key: "key",
      decided_by: %{by: :default, hooks: []}
    })

    assert_receive {:telemetry, [:wardrik, :agent, :tool_started], %{system_time: _}, metadata}

    assert metadata.agent_id == agent_id
    assert metadata.trace_id == source.trace.trace_id
    assert metadata.span_id == source.trace.span_id
    assert metadata.parent_span_id == source.trace.parent_span_id
    assert %Event{payload: %Event.ToolStarted{call_id: "call_1", name: "echo"}} = metadata.event
  end

  describe "levels as topics" do
    test "a raw subscriber is sent each event once, not once per level" do
      agent_id = Wardrik.Test.Fleet.id("levels")
      :ok = Bus.subscribe(agent_id, level: :raw)
      source = Source.root(agent_id)

      Event.emit(source, %Event.Result{text: "activity"})
      Event.emit(source, %Event.Chunk{chunk: "raw"})

      assert_receive %Event{payload: %Event.Result{text: "activity"}}
      assert_receive %Event{payload: %Event.Chunk{chunk: "raw"}}
      refute_receive %Event{}
    end

    test "unsubscribing leaves both levels" do
      agent_id = Wardrik.Test.Fleet.id("leaving")
      :ok = Bus.subscribe(agent_id, level: :raw)
      assert Bus.subscribers(agent_id) == [self()]

      :ok = Bus.unsubscribe(agent_id)

      assert Bus.subscribers(agent_id) == []
    end
  end
end
