defmodule WardrikHTTP.RouterTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.Event
  alias Wardrik.Event.Log
  alias Wardrik.Grant
  alias Wardrik.LLM.Config
  alias Wardrik.Schedule
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.EventLog
  alias Wardrik.Test.Fleet
  alias WardrikHTTP.Listener
  alias WardrikHTTP.Token

  defmodule Definition do
    @moduledoc false
    @behaviour WardrikHTTP.Definition

    @impl true
    def put(_key, %{"refuse" => message}), do: {:error, message}
    def put(key, %{"owned" => true}), do: {:error, :conflict, "#{key} belongs to a file."}
    def put(_key, %{"elsewhere" => true}), do: {:ok, Spec.new(name: "elsewhere", org: "test")}

    def put(key, %{"allow" => names}) do
      {org, user, name} = Wardrik.Fleet.parse(key)
      own = [Wardrik.Hook.new("own", Wardrik.Test.Tools.Rules, allow: names)]
      {:ok, Spec.new(name: name, org: org, user: user, hooks: own)}
    end

    def put(key, fields) do
      {org, user, name} = Wardrik.Fleet.parse(key)
      config = Config.new(model_spec: Map.get(fields, "model", "anthropic:claude-sonnet-5"))
      {:ok, Spec.new(name: name, org: org, user: user, config: config, schedules: nil)}
    end
  end

  # Keeps what it is sent in Wardrik.Store, and refuses to delete a key that
  # ends in "-owned".
  defmodule Kept do
    @moduledoc false
    @behaviour WardrikHTTP.Definition

    @ns :router_test_definitions

    @impl true
    def put(key, definition) do
      with {:ok, spec} <- Definition.put(key, definition),
           {:ok, _vsn} <- Wardrik.Store.put(@ns, key, definition),
           do: {:ok, spec}
    end

    @impl true
    def get(key) do
      case Wardrik.Store.get(@ns, key) do
        nil -> {:error, :not_found}
        definition -> {:ok, definition}
      end
    end

    @impl true
    def delete(key) do
      cond do
        String.ends_with?(key, "-owned") -> {:error, :conflict, "#{key} belongs to a file."}
        Wardrik.Store.get(@ns, key) == nil -> {:error, :not_found}
        true -> Wardrik.Store.delete(@ns, key)
      end
    end

    @impl true
    def editable(key) do
      if String.ends_with?(key, "-owned"),
        do: {:error, :conflict, "#{key} belongs to a file."},
        else: :ok
    end
  end

  setup do
    {:ok, secret, token} = Token.create("router-test", "test/", Grant.actions(), ceiling: [])
    listener = :"router-#{System.unique_integer([:positive])}"
    start_supervised!({Listener, name: listener, port: 0, definition: Definition})
    {:ok, port} = Listener.port(listener)

    %{
      api: Req.new(base_url: "http://127.0.0.1:#{port}", auth: {:bearer, secret}, retry: false),
      token: token
    }
  end

  # Another listener with `options`, and a client for it holding the same token.
  defp listener(api, options) do
    name = :"router-#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({Listener, [name: name, port: 0] ++ options}, id: name)
    )

    {:ok, port} = Listener.port(name)
    Req.merge(api, base_url: "http://127.0.0.1:#{port}")
  end

  defp echo_agent do
    {key, agent} = Fleet.start_agent(runner: {AgentRunners, :echo, [self(), "ok"]})
    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    {key, agent}
  end

  defp parked_agent do
    {key, agent} =
      Fleet.start_agent(
        runner: {AgentRunners, :parking, [self(), "call_1"]},
        resumer: {AgentRunners, :resuming, [self(), {:ok, [Context.assistant("shipped")]}]}
      )

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    Agent.ask(agent, "ship it")
    assert_receive %Event{payload: {:turn_parked, _calls}}

    {key, agent}
  end

  # An agent waiting on a person to connect an account at `link`.
  defp connecting_agent(link) do
    {key, agent} =
      Fleet.start_agent(runner: {AgentRunners, :connecting, [self(), "call_1", link]})

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    Agent.ask(agent, "open an issue")
    assert_receive %Event{payload: {:turn_parked, _calls}}

    {key, agent}
  end

  # A turn has finished, and the agent has written everything it emitted.
  defp settled(agent) do
    assert_receive %Event{payload: {:turn_finished, _messages}}
    Agent.status(agent)
  end

  describe "tokens" do
    test "a request without a token the API knows is refused", %{api: api} do
      for auth <- [nil, {:bearer, "wardrik_nope"}, {:basic, "user:pass"}] do
        assert {:ok, %{status: 401} = response} = Req.get(api, url: "/v1/agents", auth: auth)
        assert response.body["error"]["type"] == "unauthorized"

        assert Req.Response.get_header(response, "www-authenticate") == [
                 ~s(Bearer realm="wardrik")
               ]
      end
    end

    test "a token for one agent lists that agent, and none whose key it begins", %{api: api} do
      {key, _agent} = Fleet.start_agent([], Fleet.key("scoped"))
      {longer, _agent} = Fleet.start_agent([], key <> "0")
      {:ok, secret, _token} = Token.create("one-agent", key, Grant.actions(), ceiling: [])
      one = Req.merge(api, auth: {:bearer, secret})

      assert {:ok, %{status: 200, body: %{"agents" => [%{"id" => ^key}]}}} =
               Req.get(one, url: "/v1/agents")

      assert {:ok, %{status: 404}} = Req.get(one, url: "/v1/agents/#{longer}")
    end

    test "a path segment that holds a / is not a key segment", %{api: api} do
      {key, _agent} = echo_agent()
      [org, name] = String.split(key, "/")

      assert {:ok, %{status: 400, body: body}} =
               Req.get(api, url: "/v1/agents/#{org}/@jon%2F#{name}")

      assert body["error"]["message"] ==
               ~s("@jon/#{name}" holds a /; a key's org, user and name are a path segment each)
    end

    test "an agent outside the token's scope is one that does not exist", %{api: api} do
      {key, _agent} = Fleet.start_agent([], "other/hidden-#{System.unique_integer()}")

      assert {:ok, %{status: 404, body: body}} = Req.get(api, url: "/v1/agents/#{key}")
      assert body["error"]["message"] == "No agent runs under #{key}."

      {:ok, %{body: %{"agents" => agents}}} = Req.get(api, url: "/v1/agents")
      refute Enum.any?(agents, &(&1["id"] == key))
    end

    test "an action the token was not granted is refused, and an agent out of reach is hidden",
         %{api: api} do
      {key, _agent} = echo_agent()
      {:ok, secret, _token} = Token.create("watcher", "test/", [:read])
      watcher = Req.merge(api, auth: {:bearer, secret})

      assert {:ok, %{status: 200}} = Req.get(watcher, url: "/v1/agents/#{key}")

      assert {:ok, %{status: 403, body: body}} =
               Req.post(watcher, url: "/v1/agents/#{key}/messages", json: %{"content" => "hi"})

      assert body["error"] == %{
               "type" => "forbidden",
               "message" => "This token may not send messages to #{key}."
             }

      for {method, path, body} <- [
            {:post, "/interrupts/x", %{"decision" => "approve"}},
            {:post, "/cancel", %{}},
            {:delete, "/conversation", nil},
            {:put, "", %{}},
            {:delete, "", nil},
            {:put, "/schedules/sweep", %{"every" => "1h", "prompt" => "Look."}}
          ] do
        assert {:ok, %{status: 403}} =
                 Req.request(watcher, method: method, url: "/v1/agents/#{key}#{path}", json: body)
      end

      assert {:ok, %{status: 404}} =
               Req.post(watcher,
                 url: "/v1/agents/other/hidden/messages",
                 json: %{"content" => "hi"}
               )
    end

    test "a revoked token is refused, and a stream open on it ends", %{api: api} do
      {key, _agent} = echo_agent()
      {:ok, secret, token} = Token.create("revoked", "test/", Grant.actions(), ceiling: [])
      revoked = Req.merge(api, auth: {:bearer, secret})
      stream = open(revoked, key, [])

      :ok = Token.revoke(token.id)

      assert ended(stream) == :ended
      assert {:ok, %{status: 401}} = Req.get(revoked, url: "/v1/agents")
    end
  end

  test "every response carries a Request-Id, the caller's own where it sent one", %{api: api} do
    {:ok, response} = Req.get(api, url: "/v1/agents")
    assert [generated] = Req.Response.get_header(response, "request-id")
    assert byte_size(generated) >= 20

    own = "req_" <> String.duplicate("a", 24)
    {:ok, response} = Req.get(api, url: "/v1/agents", headers: [{"request-id", own}], auth: nil)
    assert Req.Response.get_header(response, "request-id") == [own]
  end

  test "answers a route it does not have, and a body that is not JSON", %{api: api} do
    assert {:ok, %{status: 404}} = Req.get(api, url: "/v2/agents")

    {key, _agent} = echo_agent()

    assert {:ok, %{status: 400, body: %{"error" => %{"message" => "The body is not JSON."}}}} =
             Req.post(api,
               url: "/v1/agents/#{key}/messages",
               body: "{nope",
               headers: [{"content-type", "application/json"}]
             )
  end

  test "lists the agents the token reaches", %{api: api} do
    {key, _agent} = echo_agent()

    assert {:ok, %{status: 200, body: %{"agents" => agents}}} = Req.get(api, url: "/v1/agents")

    assert %{"name" => name, "status" => "idle", "pending" => 0} =
             Enum.find(agents, &(&1["id"] == key))

    assert key =~ name
  end

  test "answers an agent's snapshot, with the sequence to follow its log from", %{api: api} do
    {key, agent} = echo_agent()
    Agent.ask(agent, "hi", id: "m1")
    settled(agent)

    assert {:ok, %{status: 200, body: snapshot}} = Req.get(api, url: "/v1/agents/#{key}")

    assert %{
             "agent" => %{"id" => ^key},
             "status" => "idle",
             "run" => nil,
             "interrupts" => [],
             "outcome" => "ok",
             "messages" => [%{"role" => "user"}, %{"role" => "assistant"}]
           } = snapshot

    assert snapshot["sequence"] == Agent.snapshot(agent).sequence
    assert snapshot["conversation"]["id"] == key <> "/" <> Agent.snapshot(agent).generation

    assert {:ok, %{status: 404}} = Req.get(api, url: "/v1/agents/test/nobody")
  end

  describe "keys" do
    test "a user's agent is reached under @user, with every route after it", %{api: api} do
      name = "mine-#{System.unique_integer([:positive])}"

      {key, _agent} =
        Fleet.start_agent([runner: {AgentRunners, :echo, [self(), "ok"]}], "test/@jon/#{name}")

      assert {:ok, %{status: 200, body: %{"agent" => %{"id" => ^key}}}} =
               Req.get(api, url: "/v1/agents/test/@jon/#{name}")

      assert {:ok, %{status: 200, body: %{"agent" => %{"id" => ^key}}}} =
               Req.get(api, url: "/v1/agents/test/%40jon/#{name}")

      assert {:ok, %{status: 202}} =
               Req.post(api, url: "/v1/agents/#{key}/messages", json: %{"content" => "hi"})

      assert_receive {:turn, [{:user, "hi"}]}

      assert {:ok, %{status: 404}} = Req.get(api, url: "/v1/agents/test/@ann/#{name}")
    end

    test "a path that is not an agent's key is refused, and one past it is no route", %{api: api} do
      for path <- ["/v1/agents/test/@jon", "/v1/agents/_test/x", "/v1/agents/test/_x"] do
        assert {:ok, %{status: 400, body: body}} = Req.get(api, url: path)
        assert body["error"]["message"] =~ "is not an agent key"
      end

      {key, _agent} = echo_agent()

      assert {:ok, %{status: 404, body: body}} = Req.get(api, url: "/v1/agents/#{key}/nothing")
      assert body["error"]["message"] == "No such route: GET /v1/agents/#{key}/nothing"
      assert {:ok, %{status: 404}} = Req.get(api, url: "/v1/agents/test")
    end

    test "a token scoped to a user reaches that user's agents alone", %{api: api} do
      {:ok, secret, _token} = Token.create("jon-only", "test/@jon/", [:read], ceiling: [])
      jon = Req.merge(api, auth: {:bearer, secret})
      name = "scoped-#{System.unique_integer([:positive])}"

      {mine, _agent} = Fleet.start_agent([], "test/@jon/#{name}")
      {org, _agent} = Fleet.start_agent([], "test/#{name}")

      assert {:ok, %{status: 200}} = Req.get(jon, url: "/v1/agents/#{mine}")
      assert {:ok, %{status: 404}} = Req.get(jon, url: "/v1/agents/#{org}")
      assert {:ok, %{status: 200, body: %{"agents" => agents}}} = Req.get(jon, url: "/v1/agents")
      ids = Enum.map(agents, & &1["id"])
      assert mine in ids
      refute org in ids
      assert Enum.all?(ids, &String.starts_with?(&1, "test/@jon/"))
    end
  end

  describe "messages" do
    test "queues a message under the id it was given, or one it names", %{api: api} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 202, body: %{"message" => %{"id" => "m1"}}}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/messages",
                 json: %{"id" => "m1", "parts" => [%{"type" => "text", "content" => "hi"}]}
               )

      assert_receive {:turn, [{:user, "hi"}]}

      assert {:ok, %{status: 202, body: %{"message" => %{"id" => id}}}} =
               Req.post(api, url: "/v1/agents/#{key}/messages", json: %{"content" => "again"})

      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$/
      assert_receive {:turn, [{:user, "hi"}, {:assistant, "ok"}, {:user, "again"}]}
    end

    test "refuses a message with no text, and one for an agent that does not run", %{api: api} do
      {key, _agent} = echo_agent()

      for body <- [%{}, %{"content" => ""}, %{"content" => "hi", "id" => 7}] do
        assert {:ok, %{status: 400, body: %{"error" => %{"type" => "invalid_request"}}}} =
                 Req.post(api, url: "/v1/agents/#{key}/messages", json: body)
      end

      assert {:ok, %{status: 404}} =
               Req.post(api, url: "/v1/agents/test/nobody/messages", json: %{"content" => "hi"})
    end
  end

  describe "interrupts" do
    test "a call waiting on an authorization gives its link only to a token that may decide",
         %{api: api} do
      link = %{url: "https://github.com/login/device", code: "WDJB-MJHT"}
      {key, _agent} = connecting_agent(link)

      assert {:ok, %{status: 200, body: snapshot}} = Req.get(api, url: "/v1/agents/#{key}")
      assert [%{"reason" => "authorization", "message" => message}] = snapshot["interrupts"]
      refute message =~ "github.com/login"
      refute message =~ "WDJB"

      assert {:ok, %{status: 200, body: body}} =
               Req.get(api, url: "/v1/agents/#{key}/interrupts/call_1/authorization")

      assert body == %{"url" => "https://github.com/login/device", "code" => "WDJB-MJHT"}

      {:ok, secret, _token} = Token.create("reader", "test/", [:read])

      assert {:ok, %{status: 403}} =
               Req.get(api,
                 url: "/v1/agents/#{key}/interrupts/call_1/authorization",
                 auth: {:bearer, secret}
               )

      {:ok, %{body: %{"events" => events}}} =
        Req.get(api, url: "/v1/agents/#{key}/events", params: [starting_after: 0])

      refute JSON.encode!(events) =~ "WDJB-MJHT"
      refute JSON.encode!(events) =~ "github.com/login"
    end

    test "an interrupt with no authorization has no link to give", %{api: api} do
      {key, _agent} = parked_agent()

      assert {:ok, %{status: 404, body: %{"error" => %{"message" => message}}}} =
               Req.get(api, url: "/v1/agents/#{key}/interrupts/call_1/authorization")

      assert message == "call_1 waits on no authorization."

      assert {:ok, %{status: 404}} =
               Req.get(api, url: "/v1/agents/#{key}/interrupts/nope/authorization")
    end

    test "approves a call the agent is waiting on, in the token's name", %{api: api, token: token} do
      {key, _agent} = parked_agent()

      assert {:ok, %{status: 200, body: body}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/interrupts/call_1",
                 json: %{"decision" => "approve"}
               )

      assert body == %{"interrupt" => %{"id" => "call_1", "decision" => "approved"}}
      assert_receive {:resumed, %{"call_1" => :approve}}

      assert_receive %Event{payload: {:call_decided, "call_1", :approve, by}}
      assert Wardrik.Principal.type(by) == :token
      assert Wardrik.Principal.id(by) == token.id

      assert {:ok, %{status: 409, body: %{"error" => %{"type" => "conflict"}}}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/interrupts/call_1",
                 json: %{"decision" => "approve"}
               )
    end

    test "rejects a call, with the reason given", %{api: api} do
      {key, _agent} = parked_agent()

      assert {:ok, %{status: 400}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/interrupts/call_1",
                 json: %{"decision" => "maybe"}
               )

      assert {:ok, %{status: 409}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/interrupts/call_9",
                 json: %{"decision" => "reject"}
               )

      assert {:ok, %{status: 200, body: %{"interrupt" => %{"decision" => "rejected"}}}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/interrupts/call_1",
                 json: %{"decision" => "reject", "reason" => "Not this quarter."}
               )

      assert_receive {:resumed, %{"call_1" => {:deny, "Not this quarter."}}}
    end

    test "says so when the agent cannot record the decision", %{api: api} do
      {key, _agent} = parked_agent()
      :ok = EventLog.usurp(key)

      assert {:ok, %{status: 503, body: %{"error" => %{"type" => "unavailable"}}}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/interrupts/call_1",
                 json: %{"decision" => "reject"}
               )
    end
  end

  test "cancel stops what the agent is doing", %{api: api} do
    {key, agent} =
      Fleet.start_agent(runner: {AgentRunners, :blocking, [self(), "ok"]}, grace: 10)

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    Agent.ask(agent, "wait")
    assert_receive {:turn, _messages, _turn}

    assert {:ok, %{status: 202}} = Req.post(api, url: "/v1/agents/#{key}/cancel")
    assert_receive %Event{payload: {:turn_interrupted, _stats}}

    assert {:ok, %{status: 404}} = Req.post(api, url: "/v1/agents/test/nobody/cancel")
  end

  test "clearing the conversation empties it, and waits while a turn runs", %{api: api} do
    {key, agent} =
      Fleet.start_agent(runner: {AgentRunners, :blocking, [self(), "ok"]}, grace: 10)

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "wait")
    assert_receive {:turn, _messages, turn}

    assert {:ok, %{status: 409, body: %{"error" => %{"type" => "conflict"}}}} =
             Req.delete(api, url: "/v1/agents/#{key}/conversation")

    send(turn, :release)
    assert_receive %Event{payload: {:turn_finished, _messages}}

    assert {:ok, %{status: 204}} = Req.delete(api, url: "/v1/agents/#{key}/conversation")
    assert_receive %Event{payload: {:context_cleared, 2}}
    assert Agent.get_context(agent).messages == []

    assert {:ok, %{status: 404}} = Req.delete(api, url: "/v1/agents/test/nobody/conversation")
  end

  describe "definitions" do
    defp define(api, key, body), do: Req.put(api, url: "/v1/agents/#{key}", json: body)

    defp defined_key do
      key = Fleet.key("defined")
      on_exit(fn -> Wardrik.Fleet.forget(key) end)
      key
    end

    test "start the agent they describe, then bring it to a new one", %{api: api} do
      key = defined_key()

      assert {:ok, %{status: 201, body: snapshot}} = define(api, key, %{})

      assert %{
               "agent" => %{"id" => ^key},
               "status" => "idle",
               "request" => %{"model" => "claude-sonnet-5"}
             } = snapshot

      assert {:ok, %{status: 200, body: snapshot}} =
               define(api, key, %{"model" => "openai:gpt-5"})

      assert snapshot["request"]["model"] == "gpt-5"
      assert Agent.status(key).model == "openai:gpt-5"
    end

    test "leave the agent's schedules as they are", %{api: api} do
      key = defined_key()
      {:ok, %{status: 201}} = define(api, key, %{})
      {:ok, _pid} = Schedule.put(key, "sweep", every: "30m", prompt: "Look.")

      assert {:ok, %{status: 200}} = define(api, key, %{"model" => "openai:gpt-5"})
      assert [%{name: "sweep"}] = Schedule.for_agent(key)
    end

    test "that do not read, or are not an object, start nothing", %{api: api} do
      key = defined_key()

      assert {:ok, %{status: 400, body: body}} = define(api, key, %{"refuse" => "model is text"})
      assert body["error"] == %{"type" => "invalid_request", "message" => "model is text"}

      assert {:ok, %{status: 400, body: body}} = define(api, key, ["model"])
      assert body["error"]["message"] == "The body is a JSON object"

      assert Wardrik.Fleet.lookup(key) == nil
    end

    test "outside the token's scope start nothing", %{api: api} do
      key = "other/defined-#{System.unique_integer([:positive])}"

      assert {:ok, %{status: 404}} = define(api, key, %{})
      assert Wardrik.Fleet.lookup(key) == nil
    end

    test "for one agent never start another", %{api: api} do
      key = defined_key()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{status: 500}} = define(api, key, %{"elsewhere" => true})
        end)

      assert log =~ "wrote a spec for test/elsewhere, not #{key}"
      assert Wardrik.Fleet.lookup("test/elsewhere") == nil
    end

    test "for a key the module refuses start nothing", %{api: api} do
      key = defined_key()

      assert {:ok, %{status: 409, body: body}} = define(api, key, %{"owned" => true})
      assert body["error"] == %{"type" => "conflict", "message" => "#{key} belongs to a file."}
      assert Wardrik.Fleet.lookup(key) == nil
    end

    test "are not taken, kept or deleted by a server with nothing to read them", %{api: api} do
      bare = listener(api, [])
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 501, body: body}} = define(bare, defined_key(), %{})
      assert body["error"]["type"] == "not_supported"
      assert {:ok, %{status: 501}} = Req.get(bare, url: "/v1/agents/#{key}/definition")
      assert {:ok, %{status: 501}} = Req.delete(bare, url: "/v1/agents/#{key}")
      assert Wardrik.Fleet.lookup(key)
    end

    test "are neither kept nor deleted by a module that only reads them", %{api: api} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 501, body: body}} = Req.get(api, url: "/v1/agents/#{key}/definition")
      assert body["error"]["message"] == "This server does not keep agents' definitions."
      assert {:ok, %{status: 501}} = Req.delete(api, url: "/v1/agents/#{key}")
    end
  end

  describe "a token's ceiling" do
    # A client of the same listener holding a token that defines under `ceiling`.
    defp ceiled(api, ceiling) do
      {:ok, secret, _token} = Token.create("ceiled", "test/", [:define], ceiling: ceiling)
      Req.merge(api, auth: {:bearer, secret})
    end

    # The hooks the agent under `key` runs its calls past.
    defp hooks(key) do
      %{user_state: state} = :sys.get_state(Wardrik.Fleet.whereis(key))
      Keyword.fetch!(state.scope_opts, :hooks)
    end

    defp checked(hooks, tool), do: Wardrik.Test.check(Wardrik.Test.scope(hooks: hooks), tool)

    test "holds every agent the token defines, ahead of the definition's own", %{api: api} do
      careful =
        Wardrik.Hook.new("ceiling/careful", Wardrik.Test.Tools.Rules,
          ask: ["github__issue_write"]
        )

      key = defined_key()

      assert {:ok, %{status: 201}} =
               define(ceiled(api, [careful]), key, %{"allow" => ["web_search"]})

      assert [%Wardrik.Hook{name: "ceiling/careful"}, %Wardrik.Hook{name: "own"}] = hooks(key)

      assert %Wardrik.Call{asks: [%Wardrik.Call.Ask{by: "ceiling/careful"}]} =
               checked(hooks(key), "github__issue_write")

      assert %Wardrik.Call{state: :allowed, asks: []} = checked(hooks(key), "web_search")
    end

    test "is the one an agent was last defined under, and none where that token has none",
         %{api: api} do
      ceiling = [Wardrik.Hook.new("ceiling/strict", Wardrik.Test.Tools.Rules, deny: :all)]
      key = defined_key()

      {:ok, %{status: 201}} = define(ceiled(api, ceiling), key, %{})
      assert [%Wardrik.Hook{name: "ceiling/strict"}] = hooks(key)
      assert %Wardrik.Call{state: :denied} = checked(hooks(key), "web_search")

      {:ok, %{status: 200}} = define(api, key, %{})
      assert hooks(key) == []
    end
  end

  describe "a definition module that keeps definitions" do
    setup %{api: api}, do: %{kept: listener(api, definition: Kept)}

    test "answers one back as it was sent, and forgets it with its agent", %{kept: kept} do
      key = defined_key()
      definition = %{"model" => "openai:gpt-5"}

      assert {:ok, %{status: 201}} = define(kept, key, definition)

      assert {:ok, %{status: 200, body: ^definition}} =
               Req.get(kept, url: "/v1/agents/#{key}/definition")

      assert {:ok, %{status: 204}} = Req.delete(kept, url: "/v1/agents/#{key}")
      assert Wardrik.Fleet.lookup(key) == nil
      assert {:ok, %{status: 404}} = Req.get(kept, url: "/v1/agents/#{key}/definition")
      assert {:ok, %{status: 404}} = Req.delete(kept, url: "/v1/agents/#{key}")
    end

    test "forgets an agent it kept no definition for", %{kept: kept} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 204}} = Req.delete(kept, url: "/v1/agents/#{key}")
      assert Wardrik.Fleet.lookup(key) == nil
    end

    test "leaves a stopped agent's store be, since none runs", %{kept: kept} do
      {key, _agent} = echo_agent()
      conversation = Agent.snapshot(key).generation
      :ok = Wardrik.Fleet.stop(key)

      assert {:ok, %{status: 404}} = Req.delete(kept, url: "/v1/agents/#{key}")

      {:ok, _pid} = Wardrik.Fleet.spawn(key)
      assert Agent.snapshot(key).generation == conversation
    end

    test "may refuse to delete an agent, which is left be", %{kept: kept} do
      {key, _agent} = Fleet.start_agent([], Fleet.key("kept") <> "-owned")

      assert {:ok, %{status: 409}} = Req.delete(kept, url: "/v1/agents/#{key}")
      assert Wardrik.Fleet.lookup(key)
    end

    test "may refuse to change an agent's schedules, which are left be", %{kept: kept} do
      {key, _agent} = Fleet.start_agent([], Fleet.key("kept") <> "-owned")
      {:ok, _pid} = Schedule.put(key, "sweep", every: "1h", prompt: "Look.")
      on_exit(fn -> Schedule.sync(key, []) end)

      assert {:ok, %{status: 409, body: body}} =
               Req.put(kept,
                 url: "/v1/agents/#{key}/schedules/sweep",
                 json: %{"every" => "2h", "prompt" => "Look less."}
               )

      assert body["error"]["message"] == "#{key} belongs to a file."
      assert {:ok, %{status: 409}} = Req.delete(kept, url: "/v1/agents/#{key}/schedules/sweep")
      assert [%{every: {:interval, 3_600_000}}] = Schedule.for_agent(key)
    end
  end

  describe "schedules" do
    defp schedule(api, key, name, body),
      do: Req.put(api, url: "/v1/agents/#{key}/schedules/#{name}", json: body)

    test "are put on an agent, then changed", %{api: api} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 201, body: %{"schedule" => schedule}}} =
               schedule(api, key, "sweep", %{"every" => "60m", "prompt" => "Look."})

      assert schedule == %{
               "name" => "sweep",
               "every" => "1h",
               "prompt" => "Look.",
               "overlap" => "skip",
               "missed" => "run_once",
               "jitter" => 0
             }

      assert {:ok, %{status: 200, body: %{"schedule" => schedule}}} =
               schedule(api, key, "sweep", %{
                 "every" => "*/30 * * * *",
                 "prompt" => "Look again.",
                 "overlap" => "queue",
                 "jitter" => 5
               })

      assert %{"every" => "*/30 * * * *", "overlap" => "queue", "jitter" => 5} = schedule
      assert [%{name: "sweep", every: {:cron, "*/30 * * * *"}}] = Schedule.for_agent(key)
    end

    test "that do not read, or are for an agent that does not run, are refused", %{api: api} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 400, body: body}} =
               schedule(api, key, "sweep", %{"every" => "30s", "prompt" => "Look."})

      assert body["error"]["message"] == ~s(every: "30s" is shorter than a minute)

      assert {:ok, %{status: 404}} =
               schedule(api, "test/nobody", "sweep", %{"every" => "30m", "prompt" => "Look."})

      assert Schedule.for_agent(key) == []
    end

    test "are deleted, and one that is not there is not found", %{api: api} do
      {key, _agent} = echo_agent()
      {:ok, %{status: 201}} = schedule(api, key, "sweep", %{"every" => "1d", "prompt" => "Look."})

      assert {:ok, %{status: 204}} = Req.delete(api, url: "/v1/agents/#{key}/schedules/sweep")
      assert Schedule.for_agent(key) == []

      assert {:ok, %{status: 404, body: body}} =
               Req.delete(api, url: "/v1/agents/#{key}/schedules/sweep")

      assert body["error"]["message"] == "#{key} has no schedule sweep."
    end
  end

  describe "events" do
    test "a page of the log after a sequence, as JSON", %{api: api} do
      {key, agent} = echo_agent()
      Agent.ask(agent, "hi")
      settled(agent)

      assert {:ok, %{status: 200, body: %{"events" => events}}} =
               Req.get(api,
                 url: "/v1/agents/#{key}/events",
                 params: [starting_after: 1, limit: 2]
               )

      assert Enum.map(events, & &1["type"]) == ["wardrik.message.created", "wardrik.run.started"]

      for params <- [[limit: 0], [starting_after: "soon"], [limit: "many"]] do
        assert {:ok, %{status: 400}} =
                 Req.get(api, url: "/v1/agents/#{key}/events", params: params)
      end
    end

    test "a read from before what the log holds is told where it now starts", %{api: api} do
      {key, agent} = echo_agent()
      Agent.ask(agent, "hi")
      settled(agent)
      :ok = Log.trim(key, 2, DateTime.add(DateTime.utc_now(), 1, :day))

      for headers <- [[], [{"accept", "text/event-stream"}]] do
        assert {:ok, %{status: 410, body: %{"error" => %{"type" => "gap", "oldest" => 3}}}} =
                 Req.get(api,
                   url: "/v1/agents/#{key}/events",
                   params: [starting_after: 0],
                   headers: headers
                 )
      end
    end

    test "streams the log after Last-Event-ID, then each event as it is written", %{api: api} do
      {key, agent} = echo_agent()
      Agent.ask(agent, "hi")
      settled(agent)

      stream = open(api, key, [{"last-event-id", "1"}])

      assert {[
                {"000000000002", "wardrik.message.created"},
                {"000000000003", "wardrik.run.started"},
                {"000000000004", "wardrik.run.completed"}
              ], stream} = frames(stream, 3)

      Agent.ask(agent, "again")

      assert {[
                {"000000000005", "wardrik.message.created"},
                {"000000000006", "wardrik.run.started"},
                {"000000000007", "wardrik.run.completed"}
              ], stream} = frames(stream, 3)

      Req.cancel_async_response(stream.response)
    end

    test "a stream with no cursor starts after the last event written", %{api: api} do
      {key, agent} = echo_agent()
      stream = open(api, key, [])

      Agent.ask(agent, "hi")

      assert {[{"000000000002", "wardrik.message.created"} | _rest], stream} = frames(stream, 3)
      Req.cancel_async_response(stream.response)

      assert {:ok, %{status: 404}} =
               Req.get(api,
                 url: "/v1/agents/test/nobody/events",
                 headers: [{"accept", "text/event-stream"}]
               )
    end
  end

  defp open(api, key, headers) do
    response =
      Req.get!(api,
        url: "/v1/agents/#{key}/events",
        headers: [{"accept", "text/event-stream"} | headers],
        into: :self
      )

    assert response.status == 200
    assert ["text/event-stream" <> _charset] = Req.Response.get_header(response, "content-type")
    %{response: response, buffer: ""}
  end

  # The next `count` events on the stream, as their id and type, and the
  # stream with what is left of what it has received.
  defp frames(stream, count), do: frames(stream, count, [])

  defp frames(stream, 0, frames), do: {Enum.reverse(frames), stream}

  defp frames(stream, count, frames) do
    case String.split(stream.buffer, "\n\n", parts: 2) do
      [frame, rest] ->
        frames(%{stream | buffer: rest}, count - 1, [parse(frame) | frames])

      [_partial] ->
        ref = stream.response.body.ref
        assert_receive {^ref, _part} = message
        {:ok, [data: data]} = Req.parse_message(stream.response, message)
        frames(%{stream | buffer: stream.buffer <> data}, count, frames)
    end
  end

  # Waits for the stream to end, passing over anything it sends first.
  defp ended(stream) do
    ref = stream.response.body.ref
    assert_receive {^ref, _part} = message, 2_000

    case Req.parse_message(stream.response, message) do
      {:ok, parts} -> if :done in parts, do: :ended, else: ended(stream)
      {:error, _reason} -> :ended
    end
  end

  defp parse(frame) do
    fields =
      for line <- String.split(frame, "\n"),
          [name, value] <- [String.split(line, ": ", parts: 2)],
          into: %{},
          do: {name, value}

    {fields["id"], JSON.decode!(fields["data"])["type"]}
  end

  describe "the resources' schemas" do
    @resources ~w(agent agent_snapshot authorization schedule schedule_definition error)

    defp schema(name) do
      :wardrik
      |> Application.app_dir("priv/protocol/v1/#{name}.json")
      |> File.read!()
      |> JSON.decode!()
    end

    defp conforms(value, name) do
      root = JSV.build!(schema(name), resolver: Wardrik.Test.ProtocolResolver)
      assert {:ok, _} = JSV.validate(value, root)
    end

    test "take their examples" do
      for name <- @resources, example <- schema(name)["examples"], do: conforms(example, name)
    end

    test "describe the agents listed, their snapshots idle and parked, and a schedule",
         %{api: api} do
      {idle, agent} = echo_agent()
      Agent.ask(agent, "hi")
      settled(agent)
      {parked, _agent} = parked_agent()

      {:ok, %{body: %{"agents" => agents}}} = Req.get(api, url: "/v1/agents")
      for listed <- agents, do: conforms(listed, "agent")

      for key <- [idle, parked] do
        {:ok, %{status: 200, body: snapshot}} = Req.get(api, url: "/v1/agents/#{key}")
        conforms(snapshot, "agent_snapshot")
      end

      body = %{"every" => "*/30 * * * *", "prompt" => "Look.", "jitter" => 5}
      conforms(body, "schedule_definition")

      {:ok, %{status: 201, body: %{"schedule" => schedule}}} =
        Req.put(api, url: "/v1/agents/#{idle}/schedules/sweep", json: body)

      conforms(schedule, "schedule")
    end

    test "describe every error", %{api: api} do
      {key, agent} = echo_agent()
      Agent.ask(agent, "hi")
      settled(agent)
      :ok = Log.trim(key, 2, DateTime.add(DateTime.utc_now(), 1, :day))
      {:ok, secret, _token} = Token.create("reader", "test/", [:read])

      answers = [
        Req.get(api, url: "/v1/agents", auth: nil),
        Req.get(api, url: "/v1/agents/test/nobody"),
        Req.post(api, url: "/v1/agents/#{key}/messages", json: %{}),
        Req.post(api, url: "/v1/agents/#{key}/interrupts/x", json: %{"decision" => "approve"}),
        Req.get(api, url: "/v1/agents/#{key}/events", params: [starting_after: 0]),
        Req.get(api, url: "/v1/workers"),
        Req.get(api, url: "/v1/agents/#{key}/definition"),
        Req.post(api, url: "/v1/agents/#{key}/cancel", auth: {:bearer, secret})
      ]

      assert Enum.map(answers, fn {:ok, response} -> response.status end) ==
               [401, 404, 400, 409, 410, 426, 501, 403]

      for {:ok, response} <- answers, do: conforms(response.body, "error")
    end
  end
end
