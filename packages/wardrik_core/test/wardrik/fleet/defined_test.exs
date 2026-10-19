defmodule Wardrik.Fleet.DefinedTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DurableServer.StorageBackend
  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.Event
  alias Wardrik.Fleet
  alias Wardrik.LLM.Config
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Definitions
  alias Wardrik.Test.LLM
  alias Wardrik.Test.Script

  setup do
    key = Wardrik.Test.Fleet.id()
    on_exit(fn -> Fleet.forget(key) end)
    %{key: key}
  end

  test "an agent its definition holds, and the store does not, lists asleep and answers", %{
    key: key
  } do
    Definitions.keep(key, Spec.new(id: key))

    refute Fleet.stored?(key)

    assert %Fleet.Member{asleep: true, status: :idle, pid: nil} =
             Fleet.lookup(key, host: Wardrik.Test.host())

    assert [%Fleet.Member{id: ^key, asleep: true}] =
             Fleet.list(Wardrik.AgentID.resource(key), host: Wardrik.Test.host())

    LLM.stream(Wardrik.Test.llm(), [LLM.final_answer("Hello.")])
    :ok = Event.Bus.subscribe(key)
    :ok = Agent.ask(key, "hi", host: Wardrik.Test.host())

    assert_receive %Event{payload: %Event.TurnFinished{}}, 2_000
    assert Fleet.stored?(key)
  end

  test "an agent whose state does not read starts from its definition, and says so", %{
    key: key
  } do
    {^key, _pid} =
      Wardrik.Test.Fleet.start_agent(
        [config: Script.new({AgentRunners, :echo, [self(), "ok"]})],
        key
      )

    :ok = Agent.ask(key, "hello", host: Wardrik.Test.host())
    assert_receive {:turn, _messages}
    :ok = Fleet.stop(key)
    :ok = written_earlier(key)

    Definitions.keep(key, Spec.new(id: key, config: Config.new(model_spec: "test:kept")))

    assert capture_log(fn ->
             assert %{model: "test:kept"} = Agent.status(key, host: Wardrik.Test.host())
           end) =~
             "#{key} kept a state this release cannot read"

    assert Agent.snapshot(key, host: Wardrik.Test.host()).history.messages == []
  end

  test "an agent whose state does not read, and that nothing defines, is not found", %{
    key: key
  } do
    {^key, _pid} = Wardrik.Test.Fleet.start_agent([], key)
    :ok = Fleet.stop(key)
    :ok = written_earlier(key)

    assert capture_log(fn ->
             assert {:error, :not_found} = Agent.ask(key, "hello", host: Wardrik.Test.host())
           end) =~
             "#{key} kept a state this release cannot read"

    assert Wardrik.Test.Fleet.await_update(fn -> not Fleet.stored?(key) end)
  end

  test "asks the definitions of the host it is given", %{key: key} do
    Definitions.keep(key, Spec.new(id: key))
    none = Wardrik.Host.new()

    assert Fleet.whereis(key, host: none) == nil
    assert Fleet.lookup(key, host: none) == nil
    assert Fleet.list(Wardrik.AgentID.resource(key), host: none) == []
    assert %Fleet.Member{asleep: true} = Fleet.lookup(key, host: Wardrik.Test.host())
  end

  test "a forgotten agent, its definition gone with it, stays not found", %{key: key} do
    Definitions.keep(key, Spec.new(id: key))
    assert is_pid(Fleet.whereis(key, host: Wardrik.Test.host()))

    :ok = Definitions.forget(key)
    :ok = Fleet.forget(key)

    assert Fleet.whereis(key, host: Wardrik.Test.host()) == nil
    assert Fleet.lookup(key, host: Wardrik.Test.host()) == nil
    assert Fleet.list(Wardrik.AgentID.resource(key), host: Wardrik.Test.host()) == []
    assert {:error, :not_found} = Agent.ask(key, "hello", host: Wardrik.Test.host())
  end

  # Writes the agent asleep under `key` down again as an earlier release
  # might have: with a field this one does not have.
  defp written_earlier(key) do
    %{storage_backend: backend} = DurableServer.Supervisor.__get_config__(Fleet)
    path = Fleet.prefix() <> to_string(Wardrik.AgentID.resource(key))
    {:ok, %{body: stored, etag: etag}} = StorageBackend.get_object(backend, path)
    earlier = %{stored | state: Map.put(stored.state, :scope_opts, [])}
    {:ok, _object} = StorageBackend.put_object(backend, path, earlier, etag: etag)
    :ok
  end
end
