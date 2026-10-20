defmodule Wardrik.BusTest do
  use ExUnit.Case, async: true

  alias Wardrik.Bus
  alias Wardrik.Bus.Source
  alias Wardrik.Test.Fleet

  @call %Wardrik.Conversation.ToolCall{id: "call_1", name: "deploy", arguments: %{}}

  setup do
    {:ok, agent_id: Fleet.id()}
  end

  defp emit(agent_id, payload), do: agent_id |> Source.root() |> Bus.Event.emit(payload)

  test "publish reaches every subscriber and no one else", %{agent_id: agent_id} do
    other_agent = Fleet.id()
    :ok = Bus.subscribe(agent_id)
    :ok = Bus.subscribe(other_agent)

    emit(agent_id, %Bus.Result{text: "a"})

    assert_receive %Bus.Event{payload: %Bus.Result{text: "a"}}
    refute_receive %Bus.Event{payload: %Bus.Result{text: "b"}}
  end

  test "the published event carries the source it was emitted on", %{agent_id: agent_id} do
    :ok = Bus.subscribe(agent_id)
    source = Source.root(agent_id, name: "turn")

    Bus.Event.emit(source, %Bus.Result{text: "a"})

    assert_receive %Bus.Event{source: ^source, payload: %Bus.Result{text: "a"}, at: at}
    assert is_integer(at)
  end

  test "publish with no subscribers is a no-op", %{agent_id: agent_id} do
    assert Bus.subscribers(agent_id) == []
    assert emit(agent_id, %Bus.Result{text: "a"}) == :ok
  end

  test "unsubscribe stops delivery", %{agent_id: agent_id} do
    :ok = Bus.subscribe(agent_id)
    :ok = Bus.unsubscribe(agent_id)

    assert Bus.subscribers(agent_id) == []

    emit(agent_id, %Bus.Result{text: "a"})
    refute_receive %Bus.Event{}
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

    emit(agent_id, %Bus.Result{text: "a"})
    assert_receive %Bus.Event{payload: %Bus.Result{text: "a"}}
  end

  describe "levels" do
    test "activity is what a subscriber gets by default", %{agent_id: agent_id} do
      :ok = Bus.subscribe(agent_id)

      emit(agent_id, %Bus.ToolCall{call: @call})
      emit(agent_id, %Bus.Result{text: "a"})

      assert_receive %Bus.Event{payload: %Bus.Result{text: "a"}}
      refute_received %Bus.Event{payload: %Bus.ToolCall{call: @call}}
    end

    test "raw takes each tool call as it streams too", %{agent_id: agent_id} do
      :ok = Bus.subscribe(agent_id, level: :raw)

      emit(agent_id, %Bus.ToolCall{call: @call})
      emit(agent_id, %Bus.Result{text: "a"})

      assert_receive %Bus.Event{payload: %Bus.ToolCall{call: @call}}
      assert_receive %Bus.Event{payload: %Bus.Result{text: "a"}}
    end

    test "each subscriber has its own", %{agent_id: agent_id} do
      test_pid = self()

      spawn_link(fn ->
        Bus.subscribe(agent_id, level: :raw)
        send(test_pid, :ready)
        receive do: (%Bus.Event{payload: %Bus.ToolCall{}} = e -> send(test_pid, {:other, e}))
      end)

      assert_receive :ready
      :ok = Bus.subscribe(agent_id)

      emit(agent_id, %Bus.ToolCall{call: @call})

      assert_receive {:other, %Bus.Event{payload: %Bus.ToolCall{call: @call}}}
      refute_received %Bus.Event{payload: %Bus.ToolCall{call: @call}}
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

    Bus.Event.emit(source, %Bus.ToolStarted{
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
    assert %Bus.Event{payload: %Bus.ToolStarted{call_id: "call_1", name: "echo"}} = metadata.event
  end

  describe "levels as topics" do
    test "a raw subscriber is sent each event once, not once per level" do
      agent_id = Wardrik.Test.Fleet.id("levels")
      :ok = Bus.subscribe(agent_id, level: :raw)
      source = Source.root(agent_id)

      Bus.Event.emit(source, %Bus.Result{text: "activity"})
      Bus.Event.emit(source, %Bus.ToolCall{call: @call})

      assert_receive %Bus.Event{payload: %Bus.Result{text: "activity"}}
      assert_receive %Bus.Event{payload: %Bus.ToolCall{call: @call}}
      refute_receive %Bus.Event{}
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
