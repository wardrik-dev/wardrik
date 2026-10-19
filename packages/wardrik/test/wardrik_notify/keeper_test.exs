defmodule WardrikNotify.KeeperTest do
  use ExUnit.Case, async: false

  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Script

  setup :set_req_test_to_shared

  setup do
    test = self()

    Req.Test.stub(WardrikNotify.Stub, fn conn ->
      send(test, {:notice, JSON.decode!(Req.Test.raw_body(conn))})
      Req.Test.json(conn, %{})
    end)

    user = "kept#{System.unique_integer([:positive])}"
    on_exit(fn -> Wardrik.Fleet.forget_under(Wardrik.Resource.parse!("test/@#{user}/*")) end)

    host =
      Wardrik.Test.host(
        definitions: %Definitions{store: Wardrik.Test.store(), contexts: Wardrik.context([])},
        issuer: %Wardrik.DeploymentIssuer{}
      )

    %{user: user, host: host, name: :"notify#{System.unique_integer([:positive])}"}
  end

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  defp notify(context, host \\ nil) do
    {WardrikNotify.Supervisor,
     host: host || context.host,
     name: context.name,
     targets: [audit: {WardrikNotify.Webhook, url: "https://hooks.test/wardrik"}],
     req_options: [plug: {Req.Test, WardrikNotify.Stub}],
     backoff: 0}
  end

  # An agent of the test's own, routed to audit, that parks on "call_1".
  defp parking(context) do
    id =
      AgentID.new!("agent#{System.unique_integer([:positive])}", org: "test", user: context.user)

    definitions = Wardrik.Host.definitions(context.host)

    {:ok, definition} =
      Definition.read(%{"notify" => "audit"},
        id: id,
        source: {:file, "agents/#{id.name}.md"},
        context: Definitions.context(definitions, id)
      )

    :ok = Definitions.put(definitions, definition)
    config = Script.new({AgentRunners, :parking, [self(), "call_1"]})
    {^id, pid} = Wardrik.Test.Fleet.start_agent([config: config], id)
    {id, pid}
  end

  defp parks(pid) do
    :ok = Wardrik.Agent.ask(pid, "Ship it.")
    assert_receive :asked
  end

  test "tells of what is written once it starts, and after a stop carries on from its place",
       context do
    {before, pid} = parking(context)
    parks(pid)
    start_supervised!(notify(context))

    {first, pid} = parking(context)
    parks(pid)
    assert_receive {:notice, %{"event" => "turn_parked", "agent" => agent}}, 5_000
    assert agent == to_string(first)

    stop_supervised!(WardrikNotify.Supervisor)
    {second, pid} = parking(context)
    parks(pid)
    start_supervised!(notify(context))

    assert told(second) -- [to_string(first)] == []
    earlier = to_string(before)
    refute_received {:notice, %{"agent" => ^earlier}}
  end

  # The agents told of until `agent` is: once the keeper stops before it
  # wrote down its place past a notice, it sends that one again.
  defp told(agent) do
    assert_receive {:notice, %{"event" => "turn_parked", "agent" => told}}, 5_000
    if told == to_string(agent), do: [], else: [told | told(agent)]
  end

  test "a host whose issuer does not allow the deployment its events cannot start it",
       context do
    host = %{context.host | issuer: %Wardrik.Issuer.None{}}
    assert {:error, _reason} = start_supervised(notify(context, host))
  end
end
