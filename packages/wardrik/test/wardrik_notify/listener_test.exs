defmodule WardrikNotify.ListenerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Event.Cursor
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Script

  setup :set_req_test_to_shared

  setup do
    test = self()

    Req.Test.stub(WardrikNotify.Stub, fn conn ->
      send(test, {:notice, JSON.decode!(Req.Test.raw_body(conn))})
      Req.Test.json(conn, %{})
    end)

    user = "notified#{System.unique_integer([:positive])}"
    on_exit(fn -> Wardrik.Fleet.forget_under(Wardrik.Resource.parse!("test/@#{user}/*")) end)
    %{user: user, host: host(), resources: [Wardrik.Resource.parse!("test/@#{user}/agent/*")]}
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  defp host,
    do:
      Wardrik.Test.host(
        definitions: %Definitions{store: Wardrik.Test.store(), contexts: Wardrik.context([])},
        issuer: %Wardrik.DeploymentIssuer{}
      )

  defp targets do
    [
      audit: {WardrikNotify.Webhook, url: "https://hooks.test/wardrik"},
      globex: {WardrikNotify.Webhook, url: "https://hooks.test/globex", orgs: ["globex"]}
    ]
  end

  # An agent of the test's own that parks on "call_1", or answers, routed
  # as `notify` says.
  defp agent(context, runner, notify) do
    id =
      AgentID.new!("agent#{System.unique_integer([:positive])}", org: "test", user: context.user)

    route(context, id, notify)
    {^id, pid} = Wardrik.Test.Fleet.start_agent([config: Script.new(runner)], id)
    {id, pid}
  end

  defp route(context, id, notify) do
    definitions = Wardrik.Host.definitions(context.host)

    {:ok, definition} =
      Definition.read(notify,
        id: id,
        source: {:file, "agents/#{id.name}.md"},
        context: Definitions.context(definitions, id)
      )

    :ok = Definitions.put(definitions, definition)
  end

  # The listener, with this process as its keeper, following the test's
  # agents from now on.
  defp listen(context, opts \\ []) do
    tasks = start_supervised!(Task.Supervisor)

    start_supervised!(
      {WardrikNotify.Listener,
       [
         host: context.host,
         principal: Wardrik.Principal.deployment(),
         resources: context.resources,
         types: ~w(wardrik.run.interrupted wardrik.run.failed wardrik.run.completed),
         keeper: self(),
         tasks: tasks,
         targets: targets(),
         req_options: [plug: {Req.Test, WardrikNotify.Stub}],
         backoff: 0
       ] ++ opts}
    )

    :ok
  end

  # Answers the listener's next cursor, as its keeper writes it down, once
  # it is past an entry of `agent`'s.
  defp saved(agent) do
    assert_receive {:"$gen_call", from, {:saved, cursor}}, 5_000
    GenServer.reply(from, :ok)
    {:ok, positions} = Cursor.decode(cursor)
    if Map.has_key?(positions, agent), do: cursor, else: saved(agent)
  end

  test "tells a route's targets when its agent parks, then writes down its place", context do
    listen(context)

    {key, pid} =
      agent(context, {AgentRunners, :parking, [self(), "call_1"]}, %{"notify" => "audit"})

    :ok = Wardrik.Agent.ask(pid, "Ship it.")

    assert_receive {:notice, %{"event" => "turn_parked", "agent" => agent, "calls" => [call]}},
                   5_000

    assert agent == to_string(key)
    assert %{"id" => "call_1", "name" => "deploy", "prompt" => "This ships to production."} = call
    assert {:ok, %{^key => _sequence}} = key |> saved() |> Cursor.decode()
  end

  test "reads the route as each event comes, so it sends what it asks for now", context do
    listen(context)

    {key, pid} =
      agent(context, {AgentRunners, :echo, [self(), "All quiet."]}, %{"notify" => "audit"})

    :ok = Wardrik.Agent.ask(pid, "Anything?")
    _cursor = saved(key)
    refute_received {:notice, _notice}

    route(context, key, %{"notify" => %{"to" => "audit", "on" => ["finished"]}})
    :ok = Wardrik.Agent.ask(pid, "Anything now?")

    assert_receive {:notice, %{"event" => "turn_finished", "text" => "All quiet."}}, 5_000

    route(context, key, %{})
    _cursor = saved(key)
    :ok = Wardrik.Agent.ask(pid, "And now?")
    _cursor = saved(key)
    refute_received {:notice, _notice}
  end

  test "logs a target that refuses a notice, tries it three times, and one not configured",
       context do
    test = self()

    Req.Test.stub(WardrikNotify.Stub, fn conn ->
      send(test, :refused)
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{})
    end)

    listen(context)
    route = %{"notify" => ["audit", "missing", "chat:#updates"]}
    {key, pid} = agent(context, {AgentRunners, :parking, [self(), "call_1"]}, route)

    log =
      capture_log(fn ->
        :ok = Wardrik.Agent.ask(pid, "Ship it.")
        _cursor = saved(key)
      end)

    for _attempt <- 1..3, do: assert_received(:refused)
    refute_received :refused
    assert log =~ "Could not tell audit that #{key} parked: {:status, 400}; trying again"
    assert log =~ "Could not tell audit that #{key} parked: {:status, 400}; giving up"
    assert log =~ "#{key} routes to missing, which config.yaml does not configure"
    assert log =~ "#{key} routes to chat:#updates, but this host runs no channels"
  end

  test "posts in a route's rooms through the rooms the host's channels registered", context do
    rooms = %WardrikNotify.Test.Rooms{test: self()}

    listen(%{
      context
      | host: Wardrik.Host.register(context.host, :settings, [{WardrikNotify, rooms: rooms}])
    })

    route = %{"notify" => ["chat:#updates", "audit"]}
    {key, pid} = agent(context, {AgentRunners, :parking, [self(), "call_1"]}, route)

    :ok = Wardrik.Agent.ask(pid, "Ship it.")
    _cursor = saved(key)

    assert_received {:posted, %WardrikDefinition.Room{channel: "chat", room: "#updates"},
                     %WardrikNotify.Notice{agent: ^key, kind: :parked}}

    assert_received {:notice, %{"event" => "turn_parked"}}
  end

  test "tries a delivery that crashed again", context do
    test = self()
    crashed = :counters.new(1, [])

    Req.Test.stub(WardrikNotify.Stub, fn conn ->
      if :counters.get(crashed, 1) == 0 do
        :counters.add(crashed, 1, 1)
        raise "the target fell over"
      end

      send(test, {:notice, JSON.decode!(Req.Test.raw_body(conn))})
      Req.Test.json(conn, %{})
    end)

    listen(context)

    {key, pid} =
      agent(context, {AgentRunners, :parking, [self(), "call_1"]}, %{"notify" => "audit"})

    log =
      capture_log(fn ->
        :ok = Wardrik.Agent.ask(pid, "Ship it.")
        _cursor = saved(key)
      end)

    assert_received {:notice, %{"event" => "turn_parked"}}
    refute_received {:notice, _second}
    assert log =~ "{:crashed, {%RuntimeError{message: \"the target fell over\"}"
    assert log =~ "trying again"
  end

  test "tells a target only of its own orgs' agents, and logs one routed to another's",
       context do
    listen(context)
    route = %{"notify" => ["globex", "audit"]}
    {key, pid} = agent(context, {AgentRunners, :parking, [self(), "call_1"]}, route)

    log =
      capture_log(fn ->
        :ok = Wardrik.Agent.ask(pid, "Ship it.")
        _cursor = saved(key)
      end)

    assert_received {:notice, %{"event" => "turn_parked", "agent" => agent}}
    assert agent == to_string(key)
    refute_received {:notice, _second}
    assert log =~ "#{key} routes to globex, which tells another org's agents"
  end
end
