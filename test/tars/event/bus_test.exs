defmodule Tars.Event.BusTest do
  use ExUnit.Case, async: true

  alias Tars.Event
  alias Tars.Event.Bus
  alias Tars.Event.Source

  setup do
    {:ok, agent_id: make_ref()}
  end

  defp emit(agent_id, payload), do: agent_id |> Source.root() |> Event.emit(payload)

  test "publish reaches every subscriber and no one else", %{agent_id: agent_id} do
    other_agent = make_ref()
    :ok = Bus.subscribe(agent_id)
    :ok = Bus.subscribe(other_agent)

    emit(agent_id, {:chunk, "a"})

    assert_receive %Event{payload: {:chunk, "a"}}
    refute_receive %Event{payload: {:chunk, "b"}}
  end

  test "the published event carries the source it was emitted on", %{agent_id: agent_id} do
    :ok = Bus.subscribe(agent_id)
    source = Source.root(agent_id, name: "turn")

    Event.emit(source, {:chunk, "a"})

    assert_receive %Event{source: ^source, payload: {:chunk, "a"}, at: at}
    assert is_integer(at)
  end

  test "publish with no subscribers is a no-op", %{agent_id: agent_id} do
    assert Bus.subscribers(agent_id) == []
    assert emit(agent_id, {:chunk, "a"}) == :ok
  end

  test "unsubscribe stops delivery", %{agent_id: agent_id} do
    :ok = Bus.subscribe(agent_id)
    :ok = Bus.unsubscribe(agent_id)

    assert Bus.subscribers(agent_id) == []

    emit(agent_id, {:chunk, "a"})
    refute_receive %Event{}
  end

  test "a dead subscriber does not affect the others" do
    agent_id = make_ref()
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

    emit(agent_id, {:chunk, "a"})
    assert_receive %Event{payload: {:chunk, "a"}}
  end

  test "events are published as telemetry, stamped with the span", %{agent_id: agent_id} do
    handler_id = {__MODULE__, agent_id}
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:tars, :agent, :tool_started],
        fn name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    source = Source.root(agent_id) |> Source.child()
    Event.emit(source, {:tool_started, "call_1", "echo"})

    assert_receive {:telemetry, [:tars, :agent, :tool_started], %{system_time: _}, metadata}

    assert metadata.agent_id == agent_id
    assert metadata.trace_id == source.trace.trace_id
    assert metadata.span_id == source.trace.span_id
    assert metadata.parent_span_id == source.trace.parent_span_id
    assert %Event{payload: {:tool_started, "call_1", "echo"}} = metadata.event
  end
end
