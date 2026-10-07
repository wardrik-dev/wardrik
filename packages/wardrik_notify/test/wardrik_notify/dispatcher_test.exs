defmodule WardrikNotify.DispatcherTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wardrik.Agent
  alias Wardrik.Fleet
  alias Wardrik.Test.AgentRunners
  alias WardrikNotify.Route

  setup :set_req_test_to_shared

  setup do
    previous = Application.get_env(:wardrik_notify, WardrikNotify)

    Application.put_env(
      :wardrik_notify,
      WardrikNotify,
      Keyword.put(previous, :targets,
        audit: {WardrikNotify.Webhook, url: "https://hooks.test/wardrik"},
        globex: {WardrikNotify.Webhook, url: "https://hooks.test/globex", orgs: ["globex"]}
      )
    )

    on_exit(fn -> Application.put_env(:wardrik_notify, WardrikNotify, previous) end)

    test = self()

    Req.Test.stub(WardrikNotify.Stub, fn conn ->
      send(test, {:notice, JSON.decode!(Req.Test.raw_body(conn))})
      Req.Test.json(conn, %{})
    end)

    start_supervised!(WardrikNotify.Supervisor)

    key = Wardrik.Test.Fleet.id("notified")
    on_exit(fn -> Fleet.forget(key) end)
    %{key: key}
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  test "tells a route's targets when its agent parks", %{key: key} do
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :parking, [self(), "call_1"]})
    :ok = WardrikNotify.put_routes(%{key => %Route{targets: [:audit]}})

    :ok = Agent.ask(key, "Ship it.")

    assert_receive {:notice, %{"event" => "turn_parked", "agent" => agent, "calls" => [call]}}
    assert agent == to_string(key)
    assert %{"id" => "call_1", "name" => "deploy", "prompt" => "This ships to production."} = call
  end

  test "sends what a turn answered only to a route that asks for it", %{key: key} do
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :echo, [self(), "All quiet."]})

    :ok = WardrikNotify.put_routes(%{key => %Route{targets: [:audit]}})
    :ok = Agent.ask(key, "Anything?")
    assert_receive {:turn, _context}
    refute_receive {:notice, _notice}

    :ok = WardrikNotify.put_routes(%{key => %Route{targets: [:audit], on: [:finished]}})
    :ok = Agent.ask(key, "Anything now?")

    assert_receive {:notice, %{"event" => "turn_finished", "text" => "All quiet."}}
  end

  test "an agent left out of the routes is no longer heard", %{key: key} do
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :parking, [self(), "call_1"]})
    :ok = WardrikNotify.put_routes(%{key => %Route{targets: [:audit]}})
    :ok = WardrikNotify.put_routes(%{})

    :ok = Agent.ask(key, "Ship it.")
    assert_receive :asked
    refute_receive {:notice, _notice}
  end

  test "logs a target that refuses a notice, and one config.yaml does not name", %{key: key} do
    test = self()

    Req.Test.stub(WardrikNotify.Stub, fn conn ->
      send(test, :refused)
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{})
    end)

    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :parking, [self(), "call_1"]})
    :ok = WardrikNotify.put_routes(%{key => %Route{targets: [:audit, :missing]}})

    log =
      capture_log(fn ->
        :ok = Agent.ask(key, "Ship it.")
        assert_receive :refused
        wait_for_deliveries()
      end)

    assert log =~ "Could not tell audit that #{key} parked: {:status, 400}"
    assert log =~ "#{key} routes to missing, which config.yaml does not configure"
  end

  test "tells a target only of its own orgs' agents, and logs one routed to another's", %{
    key: key
  } do
    {:ok, _pid} = Fleet.spawn(key, runner: {AgentRunners, :parking, [self(), "call_1"]})
    :ok = WardrikNotify.put_routes(%{key => %Route{targets: [:globex, :audit]}})

    log =
      capture_log(fn ->
        :ok = Agent.ask(key, "Ship it.")
        assert_receive {:notice, %{"event" => "turn_parked", "agent" => agent}}
        assert agent == to_string(key)
        wait_for_deliveries()
      end)

    refute_receive {:notice, _second}
    assert log =~ "#{key} routes to globex, which tells another org's agents"
  end

  test "ignores what is not an event" do
    send(WardrikNotify.Dispatcher, :stray)
    assert :ok = WardrikNotify.put_routes(%{})
  end

  # Each delivery is a task under WardrikNotify.TaskSupervisor, done once it has
  # logged what became of it.
  defp wait_for_deliveries do
    for pid <- Task.Supervisor.children(WardrikNotify.TaskSupervisor) do
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    end

    if Task.Supervisor.children(WardrikNotify.TaskSupervisor) != [], do: wait_for_deliveries()
  end
end
