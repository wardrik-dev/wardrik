defmodule Tars.EventsTest do
  use ExUnit.Case, async: true

  alias Tars.Events

  setup do
    {:ok, agent_id: make_ref()}
  end

  test "emit reaches every subscriber and no one else", %{agent_id: agent_id} do
    other_agent = make_ref()
    :ok = Events.subscribe(agent_id)
    :ok = Events.subscribe(other_agent)

    Events.emit(agent_id, {:chunk, "a"})

    assert_receive {:chunk, "a"}
    refute_receive {:chunk, "b"}
  end

  test "emit with no subscribers is a no-op", %{agent_id: agent_id} do
    assert Events.subscribers(agent_id) == []
    assert Events.emit(agent_id, {:chunk, "a"}) == :ok
  end

  test "unsubscribe stops delivery", %{agent_id: agent_id} do
    :ok = Events.subscribe(agent_id)
    :ok = Events.unsubscribe(agent_id)

    assert Events.subscribers(agent_id) == []

    Events.emit(agent_id, {:chunk, "a"})
    refute_receive {:chunk, "a"}
  end

  test "a dead subscriber does not affect the others" do
    agent_id = make_ref()
    test_pid = self()
    :ok = Events.subscribe(agent_id)

    {dead, ref} =
      spawn_monitor(fn ->
        Events.subscribe(agent_id)
        send(test_pid, :subscribed)
        receive do: (:stop -> :ok)
      end)

    assert_receive :subscribed
    send(dead, :stop)
    assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

    Events.emit(agent_id, {:chunk, "a"})
    assert_receive {:chunk, "a"}
  end

  test "events are published as telemetry", %{agent_id: agent_id} do
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

    Events.emit(agent_id, {:tool_started, "call_1", "echo"})

    assert_receive {:telemetry, [:tars, :agent, :tool_started], %{system_time: _},
                    %{agent_id: ^agent_id, event: {:tool_started, "call_1", "echo"}}}
  end
end
