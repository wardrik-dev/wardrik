defmodule WardrikMCP.RobustnessTest do
  use WardrikMCP.Test.Case, async: false

  alias Wardrik.Event
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Run
  alias WardrikMCP.Connection

  setup %{key: key} do
    agent_id = Wardrik.Test.Fleet.id()
    :ok = Event.Bus.subscribe(agent_id)

    run = Config.new(tools: [{WardrikMCP, key}]) |> Run.root(agent_id, name: "turn")

    %{agent_id: agent_id, run: run}
  end

  describe "a caller that stops waiting" do
    test "cancels the request the server is still working on", context do
      %{key: key, agent_id: agent_id, run: run} = context

      batch = start_call(run, "call_slow", "#{key}__slow")
      await_reached_server("call_slow")

      assert :ok = ToolRunner.kill_call(agent_id, "call_slow")

      assert [%Wardrik.Call{state: :done}] = Task.await(batch)
      assert await_cancelled(key) == 1
    end

    test "leaves the calls of other callers alone", context do
      %{key: key, agent_id: agent_id, run: run} = context

      batch = start_call(run, "call_slow", "#{key}__slow")
      await_reached_server("call_slow")

      answering =
        Task.async(fn ->
          WardrikMCP.call(key, "echo", %{"value" => "still here"}, context())
        end)

      assert :ok = ToolRunner.kill_call(agent_id, "call_slow")

      assert {:ok, %{"result" => %{"content" => "still here"}}} = Task.await(answering)
      assert [%Wardrik.Call{state: :done}] = Task.await(batch)
      assert await_cancelled(key) == 1
    end

    test "a call that ends of its own accord cancels nothing", %{key: key} do
      assert {:ok, %{"ok" => true}} =
               Task.await(
                 Task.async(fn ->
                   WardrikMCP.call(key, "echo", %{"value" => "done"}, context())
                 end)
               )

      assert cancelled(key) == 0
    end
  end

  describe "progress" do
    test "a server's progress lands on the turn's event stream", context do
      %{key: key, run: run} = context
      name = "#{key}__noisy"
      call = %{id: "call_noisy", name: name, arguments: %{"steps" => 3}}

      assert %Wardrik.Call{state: :done} = ToolRunner.execute(call, run)

      assert_receive %Event{
                       payload: %Event.ToolProgress{
                         call_id: "call_noisy",
                         name: ^name,
                         progress: 1,
                         total: 3
                       }
                     },
                     5_000

      assert_receive %Event{
                       payload: %Event.ToolProgress{
                         call_id: "call_noisy",
                         name: ^name,
                         progress: 3,
                         total: 3
                       }
                     },
                     5_000
    end

    test "a call outside a turn reports none and still answers", %{key: key} do
      assert {:ok, %{"result" => %{"content" => "done in 2"}}} =
               WardrikMCP.call(key, "noisy", %{}, context())

      refute_receive %Event{payload: %Event.ToolProgress{}}, 100
    end
  end

  describe "a client that dies" do
    @describetag capture_log: true

    test "is started again, and the connection outlives it", %{key: key} do
      connection = connection(key)
      client = :sys.get_state(connection).client
      monitor = Process.monitor(client)

      Process.exit(client, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^client, :killed}

      assert [_tool | _rest] = await_tools(key)
      assert Process.alive?(connection)

      assert {:ok, %{"ok" => true}} =
               WardrikMCP.call(key, "echo", %{"value" => "back"}, context())
    end

    test "a client Anubis restarts for itself keeps answering", %{key: key} do
      connection = connection(key)
      client = key |> Connection.client() |> GenServer.whereis()
      monitor = Process.monitor(client)

      Process.exit(client, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^client, :killed}

      assert Process.alive?(connection)
      assert [_tool | _rest] = await_tools(key)
    end
  end

  # The batch runs the call in a task of the runner's own, which is the process
  # `kill_call/2` stops; awaiting the batch itself would wait for that kill.
  defp start_call(run, id, name) do
    call = %{id: id, name: name, arguments: %{}}

    Task.async(fn -> ToolRunner.execute_many_async([call], run) end)
  end

  # `slow` answers nothing and reports progress once, so its progress event is
  # the only word that the server has the request.
  defp await_reached_server(call_id) do
    assert_receive %Event{payload: %Event.ToolProgress{call_id: ^call_id, progress: 1, total: 1}},
                   5_000
  end

  # The cancellation is sent from a task of the connection's, so it races this
  # call rather than preceding it. Each attempt is a round trip to the server,
  # which is what paces the wait.
  defp await_cancelled(key, attempts \\ 100) do
    case {cancelled(key), attempts} do
      {0, attempts} when attempts > 0 -> await_cancelled(key, attempts - 1)
      {count, _attempts} -> count
    end
  end

  defp cancelled(key) do
    {:ok, %{"result" => %{"content" => count}}} =
      WardrikMCP.call(key, "cancellations", %{}, context())

    String.to_integer(count)
  end

  defp connection(key) do
    GenServer.whereis({:via, Registry, {WardrikMCP.Registry, {:connection, key, :deployment}}})
  end
end
