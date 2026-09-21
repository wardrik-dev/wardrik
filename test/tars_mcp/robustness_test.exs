defmodule TarsMCP.RobustnessTest do
  use Tars.Test.MCPCase, async: false

  alias Tars.Event
  alias Tars.LLM.Config
  alias Tars.LLM.ToolRunner
  alias Tars.Scope
  alias TarsMCP.Connection

  setup %{ref: ref} do
    agent_id = Tars.Test.Fleet.key()
    :ok = Event.Bus.subscribe(agent_id)

    scope = Config.new(tools: [{TarsMCP, ref}]) |> Scope.root(agent_id, name: "turn")

    %{agent_id: agent_id, scope: scope}
  end

  describe "a caller that stops waiting" do
    test "cancels the request the server is still working on", context do
      %{ref: ref, agent_id: agent_id, scope: scope} = context

      batch = start_call(scope, "call_slow", "#{ref}__slow")
      await_reached_server("call_slow")

      assert :ok = ToolRunner.kill_call(agent_id, "call_slow")

      assert [{:settled, _call, _message}] = Task.await(batch)
      assert await_cancelled(ref) == 1
    end

    test "leaves the calls of other callers alone", context do
      %{ref: ref, agent_id: agent_id, scope: scope} = context

      batch = start_call(scope, "call_slow", "#{ref}__slow")
      await_reached_server("call_slow")

      answering = Task.async(fn -> TarsMCP.call(ref, "echo", %{"value" => "still here"}) end)

      assert :ok = ToolRunner.kill_call(agent_id, "call_slow")

      assert {:ok, %{"result" => %{"content" => "still here"}}} = Task.await(answering)
      assert [{:settled, _call, _message}] = Task.await(batch)
      assert await_cancelled(ref) == 1
    end

    test "a call that ends of its own accord cancels nothing", %{ref: ref} do
      assert {:ok, %{"ok" => true}} =
               Task.await(Task.async(fn -> TarsMCP.call(ref, "echo", %{"value" => "done"}) end))

      assert cancelled(ref) == 0
    end
  end

  describe "progress" do
    test "a server's progress lands on the turn's event stream", context do
      %{ref: ref, scope: scope} = context
      name = "#{ref}__noisy"
      call = %{id: "call_noisy", name: name, arguments: %{"steps" => 3}}

      assert {:settled, _call, _message} = ToolRunner.execute(call, scope)

      assert_receive %Event{payload: {:tool_progress, "call_noisy", ^name, 1, 3}}, 5_000
      assert_receive %Event{payload: {:tool_progress, "call_noisy", ^name, 3, 3}}, 5_000
    end

    test "a call outside a turn reports none and still answers", %{ref: ref} do
      assert {:ok, %{"result" => %{"content" => "done in 2"}}} = TarsMCP.call(ref, "noisy", %{})

      refute_receive %Event{payload: {:tool_progress, _id, _name, _progress, _total}}, 100
    end
  end

  describe "a client that dies" do
    @describetag capture_log: true

    test "is started again, and the connection outlives it", %{ref: ref} do
      connection = connection(ref)
      client = :sys.get_state(connection).client
      monitor = Process.monitor(client)

      Process.exit(client, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^client, :killed}

      assert [_tool | _rest] = await_tools(ref)
      assert Process.alive?(connection)
      assert {:ok, %{"ok" => true}} = TarsMCP.call(ref, "echo", %{"value" => "back"})
    end

    test "a client Anubis restarts for itself keeps answering", %{ref: ref} do
      connection = connection(ref)
      client = ref |> Connection.client() |> GenServer.whereis()
      monitor = Process.monitor(client)

      Process.exit(client, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^client, :killed}

      assert Process.alive?(connection)
      assert [_tool | _rest] = await_tools(ref)
    end
  end

  # The batch runs the call in a task of the runner's own, which is the process
  # `kill_call/2` stops; awaiting the batch itself would wait for that kill.
  defp start_call(scope, id, name) do
    call = %{id: id, name: name, arguments: %{}}

    Task.async(fn -> ToolRunner.execute_many_async([call], scope) end)
  end

  # `slow` answers nothing and reports progress once, so its progress event is
  # the only word that the server has the request.
  defp await_reached_server(call_id) do
    assert_receive %Event{payload: {:tool_progress, ^call_id, _name, 1, 1}}, 5_000
  end

  # The cancellation is sent from a task of the connection's, so it races this
  # call rather than preceding it. Each attempt is a round trip to the server,
  # which is what paces the wait.
  defp await_cancelled(ref, attempts \\ 100) do
    case {cancelled(ref), attempts} do
      {0, attempts} when attempts > 0 -> await_cancelled(ref, attempts - 1)
      {count, _attempts} -> count
    end
  end

  defp cancelled(ref) do
    {:ok, %{"result" => %{"content" => count}}} = TarsMCP.call(ref, "cancellations", %{})

    String.to_integer(count)
  end

  defp connection(ref) do
    GenServer.whereis({:via, Registry, {TarsMCP.Registry, {:connection, ref, :deployment}}})
  end
end
