defmodule WardrikHTTP.RouterTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias ReqLLM.Context
  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Event
  alias Wardrik.Event.Log
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.LLM.Config
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Audit
  alias Wardrik.Test.EventLog
  alias Wardrik.Test.Fleet
  alias WardrikHTTP.Listener
  alias WardrikHTTP.Token

  defmodule Definition do
    @moduledoc false
    defstruct []

    def put(_host, _key, %{"refuse" => message}, _grant), do: {:error, message}

    def put(_host, key, %{"owned" => true}, _grant),
      do: {:error, :conflict, "#{key} belongs to a file."}

    def put(_host, _key, %{"elsewhere" => true}, _grant),
      do: {:ok, Spec.new(id: Wardrik.AgentID.parse!("test/elsewhere"))}

    def put(_host, key, %{"allow" => names}, _grant) do
      own = [Wardrik.Hook.new("own", Wardrik.Test.Tools.Rules, allow: names)]
      {:ok, Spec.new(id: key, hooks: own)}
    end

    def put(_host, key, fields, _grant) do
      config = Config.new(model_spec: Map.get(fields, "model", "anthropic:claude-sonnet-5"))
      {:ok, Spec.new(id: key, config: config)}
    end
  end

  defimpl Wardrik.Definition, for: Definition do
    use Wardrik.Definition.None
    def put(d, key, opts), do: Definition.put(d, key, opts[:definition], opts[:grant])
  end

  # Keeps what it is sent in WardrikStore, triggers beside definitions, and
  # refuses to change an agent whose name holds "-owned".
  defmodule Kept do
    @moduledoc false
    defstruct []

    @ns :router_test_definitions
    @triggers :router_test_triggers

    def put(host, key, definition, grant) do
      with {:ok, spec} <- Definition.put(host, key, definition, grant),
           {:ok, _vsn} <- WardrikStore.put(store(), @ns, to_string(key), definition),
           do: {:ok, spec}
    end

    def get(_host, key) do
      case WardrikStore.get(store(), @ns, to_string(key)) do
        nil -> {:error, :not_found}
        fields -> {:ok, %Wardrik.Definition.Read{fields: fields, missing: []}}
      end
    end

    def delete(_host, key) do
      cond do
        String.contains?(key.name, "-owned") -> {:error, :conflict, "#{key} belongs to a file."}
        WardrikStore.get(store(), @ns, to_string(key)) == nil -> {:error, :not_found}
        true -> WardrikStore.delete(store(), @ns, to_string(key))
      end
    end

    def put_trigger(_host, _key, _name, %{"refuse" => message}), do: {:error, message}

    def put_trigger(host, key, name, fields) do
      with :ok <- editable(host, key),
           {:ok, _definition} <- get(host, key) do
        status = if triggered(key, name), do: :changed, else: :created
        defaults = %{"name" => name, "overlap" => "skip", "missed" => "run_once", "jitter" => 0}
        trigger = Map.merge(defaults, fields)
        {:ok, _vsn} = WardrikStore.put(store(), @triggers, "#{key}//#{name}", trigger)
        {:ok, status, trigger}
      end
    end

    def delete_trigger(host, key, name) do
      with :ok <- editable(host, key) do
        if triggered(key, name),
          do: WardrikStore.delete(store(), @triggers, "#{key}//#{name}"),
          else: {:error, :not_found}
      end
    end

    defp triggered(key, name), do: WardrikStore.get(store(), @triggers, "#{key}//#{name}")

    def editable(_host, key) do
      if String.contains?(key.name, "-owned"),
        do: {:error, :conflict, "#{key} belongs to a file."},
        else: :ok
    end
  end

  defimpl Wardrik.Definition, for: Kept do
    use Wardrik.Definition.None
    def put(d, key, opts), do: Kept.put(d, key, opts[:definition], opts[:grant])
    defdelegate get(d, key), to: Kept
    defdelegate delete(d, key), to: Kept
    def put_trigger(d, key, name, opts), do: Kept.put_trigger(d, key, name, opts[:fields])
    defdelegate delete_trigger(d, key, name), to: Kept
    defdelegate editable(d, key), to: Kept
  end

  # Knows a request by its x-user header, as a person who may do anything
  # under test/; a sign-in would answer a caller the same way.
  defmodule Signed do
    @moduledoc false
    defstruct []
  end

  defimpl WardrikHTTP.Authenticator, for: Signed do
    def authenticate(_signed, conn) do
      case Plug.Conn.get_req_header(conn, "x-user") do
        [user] ->
          {:ok, grant} = Grant.new(Prefix.parse!("test/"))

          {:ok,
           %WardrikHTTP.Caller{
             id: "session-#{user}",
             name: user,
             principal: Wardrik.Principal.new(:user, user),
             grant: grant
           }}

        [] ->
          {:error, :unauthorized}
      end
    end

    def challenge(_signed), do: ~s(Signed realm="test")
  end

  # Offers github, held by jon in test, and linear, held by nobody.
  defmodule Linked do
    @moduledoc false
    defstruct []

    def list(_host, owner) do
      [
        %{provider: "github", held_by: if(owner == {"test", "jon"}, do: :person)},
        %{provider: "linear", held_by: nil}
      ]
    end

    def connect(_host, "github", {"test", "jon"}, _by), do: {:ok, :held}

    def connect(_host, provider, _owner, _by) when provider in ["github", "linear"],
      do: {:ok, %{url: "https://auth.example.com/#{provider}", code: nil}}

    def connect(_host, _provider, _owner, _by), do: {:error, :not_found}

    def disconnect(_host, "github", {"test", "jon"}), do: :ok
    def disconnect(_host, _provider, _owner), do: {:error, :not_found}
  end

  defimpl Wardrik.Connections, for: Linked do
    defdelegate list(c, owner), to: Linked
    defdelegate connect(c, provider, owner, opts), to: Linked
    defdelegate disconnect(c, provider, owner), to: Linked
  end

  # Has test/@jon/'s docs, adds docs and crm, the second behind a sign-in,
  # and has taken already.
  defmodule Added do
    @moduledoc false
    defstruct []

    def list(_servers, owner) do
      if to_string(owner) == "test/@jon/",
        do: [%Wardrik.Servers.Listed{name: "docs", url: "https://docs.example/mcp", auth: "none"}],
        else: []
    end

    def add(_servers, _owner, name: "docs", fields: _fields, by: _by), do: {:ok, :connected}

    def add(_servers, _owner, name: "crm", fields: _fields, by: _by),
      do: {:ok, %{url: "https://auth.example.com/crm", code: nil}}

    def add(_servers, _owner, _opts),
      do: {:error, Wardrik.Error.new(:conflict, "taken is there already.")}

    def remove(_servers, _owner, name: "docs", by: _by), do: :ok

    def remove(_servers, owner, name: name, by: _by),
      do: {:error, Wardrik.Error.new(:not_found, "#{owner} added no #{name}.")}
  end

  defimpl Wardrik.Servers, for: Added do
    defdelegate list(s, owner), to: Added
    defdelegate add(s, owner, opts), to: Added
    defdelegate remove(s, owner, opts), to: Added
  end

  # Hands the test each request a trigger is delivered, and answers by its
  # body; operations run in the process serving the request.
  defmodule Hooked do
    @moduledoc false
    defstruct []

    def deliver(key, name, %{headers: headers, body: body}) do
      send(:persistent_term.get(__MODULE__), {:delivered, key, name, headers, body})

      case body do
        "seen" -> {:ok, :seen}
        "forged" -> {:error, :forbidden, "The request's signature does not match."}
        "busy" -> {:error, :unavailable, "The agent is busy."}
        "nowhere" -> {:error, :not_found}
        _new -> {:ok, :asked}
      end
    end
  end

  defimpl Wardrik.Triggers, for: Hooked do
    def deliver(_t, key, name, opts), do: Hooked.deliver(key, name, opts[:request])
  end

  # Cannot check any credential now, as an identity provider that is down.
  defmodule Down do
    @moduledoc false
    defstruct []
  end

  defimpl WardrikHTTP.Authenticator, for: Down do
    def authenticate(_down, _conn), do: {:error, :unavailable}
    def challenge(_down), do: ~s(Down realm="test")
  end

  defp host,
    do:
      Host.new(
        store: Wardrik.Test.store(),
        definitions: %Definition{},
        connections: %Linked{},
        servers: %Added{},
        triggers: %Hooked{}
      )

  setup do
    {:ok, secret, token} =
      Token.create(store(), "router-test",
        scope: Prefix.parse!("test/"),
        can: Grant.actions(),
        ceiling: []
      )

    listener = :"router-#{System.unique_integer([:positive])}"
    start_supervised!({Listener, name: listener, port: 0, host: host()})
    {:ok, port} = Listener.port(listener)

    %{
      api: Req.new(base_url: "http://127.0.0.1:#{port}", auth: {:bearer, secret}, retry: false),
      token: token
    }
  end

  # Another listener with `options`, on the suite's host unless they name
  # another, and a client for it holding the same token.
  defp listener(api, options) do
    name = :"router-#{System.unique_integer([:positive])}"
    options = Keyword.merge([name: name, port: 0, host: host()], options)

    start_supervised!(Supervisor.child_spec({Listener, options}, id: name))

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
    assert_receive %Event{payload: %Event.TurnParked{}}

    {key, agent}
  end

  # An agent waiting on a person to connect an account at `link`.
  defp connecting_agent(link) do
    {key, agent} =
      Fleet.start_agent(runner: {AgentRunners, :connecting, [self(), "call_1", link]})

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    Agent.ask(agent, "open an issue")
    assert_receive %Event{payload: %Event.TurnParked{}}

    {key, agent}
  end

  # A turn has finished, and the agent has written everything it emitted.
  defp settled(agent) do
    assert_receive %Event{payload: %Event.TurnFinished{}}
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

    test "another authenticator knows the caller, and decisions are its principal's", %{
      api: api
    } do
      signed = listener(api, authenticator: %Signed{})

      assert {:ok, %{status: 401} = response} = Req.get(signed, url: "/v1/agents")
      assert Req.Response.get_header(response, "www-authenticate") == [~s(Signed realm="test")]

      jon = Req.merge(signed, auth: nil, headers: [{"x-user", "jon"}])
      {key, _agent} = parked_agent()

      assert {:ok, %{status: 200}} =
               Req.post(jon,
                 url: "/v1/agents/#{key}/decisions",
                 json: %{"decisions" => [%{"id" => "call_1", "decision" => "approve"}]}
               )

      assert_receive %Event{
        payload: %Event.CallDecided{call_id: "call_1", decision: :approve, by: by}
      }

      assert {Wardrik.Principal.type(by), Wardrik.Principal.id(by)} == {:user, "jon"}
    end

    test "a credential the authenticator cannot check now is answered unavailable", %{
      api: api
    } do
      down = listener(api, authenticator: %Down{})

      assert {:ok, %{status: 503, body: body}} = Req.get(down, url: "/v1/agents")
      assert body["error"]["type"] == "unavailable"
    end

    test "a token for one agent lists that agent, and none whose key it begins", %{api: api} do
      {key, _agent} = Fleet.start_agent([], Fleet.id("scoped"))
      longer_id = Wardrik.AgentID.new!(key.name <> "0", org: key.org)
      {longer, _agent} = Fleet.start_agent([], longer_id)

      {:ok, secret, _token} =
        Token.create(store(), "one-agent",
          scope: Prefix.of(key),
          can: Grant.actions(),
          ceiling: []
        )

      one = Req.merge(api, auth: {:bearer, secret})

      text = to_string(key)

      assert {:ok, %{status: 200, body: %{"agents" => [%{"id" => ^text}]}}} =
               Req.get(one, url: "/v1/agents")

      assert {:ok, %{status: 404}} = Req.get(one, url: "/v1/agents/#{longer}")
    end

    test "a path segment that holds a / is not an ID's segment", %{api: api} do
      {%{org: org, name: name}, _agent} = echo_agent()

      assert {:ok, %{status: 400, body: body}} =
               Req.get(api, url: "/v1/agents/#{org}/@jon%2F#{name}")

      assert body["error"]["message"] ==
               ~s("@jon/#{name}" holds a /; an ID's org, user and name are a path segment each)
    end

    test "an agent outside the token's scope is one that does not exist", %{api: api} do
      {key, _agent} =
        Fleet.start_agent(
          [],
          Wardrik.AgentID.new!("hidden-#{System.unique_integer([:positive])}", org: "other")
        )

      assert {:ok, %{status: 404, body: body}} = Req.get(api, url: "/v1/agents/#{key}")
      assert body["error"]["message"] == "No agent runs under #{key}."

      {:ok, %{body: %{"agents" => agents}}} = Req.get(api, url: "/v1/agents")
      refute Enum.any?(agents, &(&1["id"] == key))
    end

    test "an action the token was not granted is refused, and an agent out of reach is hidden",
         %{api: api} do
      {key, _agent} = echo_agent()

      {:ok, secret, _token} =
        Token.create(store(), "watcher", scope: Prefix.parse!("test/"), can: [:read])

      watcher = Req.merge(api, auth: {:bearer, secret})

      assert {:ok, %{status: 200}} = Req.get(watcher, url: "/v1/agents/#{key}")

      assert {:ok, %{status: 403, body: body}} =
               Req.post(watcher, url: "/v1/agents/#{key}/messages", json: %{"content" => "hi"})

      assert body["error"] == %{
               "type" => "forbidden",
               "message" => "This caller may not send messages to #{key}."
             }

      for {method, path, body} <- [
            {:post, "/decisions", %{"decisions" => [%{"id" => "x", "decision" => "approve"}]}},
            {:post, "/cancel", %{}},
            {:delete, "/conversation", nil},
            {:put, "", %{}},
            {:delete, "", nil},
            {:put, "/triggers/sweep", %{"every" => "1h", "prompt" => "Look."}}
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

      {:ok, secret, token} =
        Token.create(store(), "revoked",
          scope: Prefix.parse!("test/"),
          can: Grant.actions(),
          ceiling: []
        )

      revoked = Req.merge(api, auth: {:bearer, secret})
      stream = open(revoked, key, [])

      :ok = Token.revoke(store(), token.id)

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
             Enum.find(agents, &(&1["id"] == to_string(key)))

    assert to_string(key) =~ name
  end

  test "answers an agent's snapshot, with the sequence to follow its log from", %{api: api} do
    {key, agent} = echo_agent()
    Agent.ask(agent, "hi", id: "m1")
    settled(agent)

    assert {:ok, %{status: 200, body: snapshot}} = Req.get(api, url: "/v1/agents/#{key}")
    text = to_string(key)

    assert %{
             "agent" => %{"id" => ^text},
             "status" => "idle",
             "run" => nil,
             "interrupts" => [],
             "outcome" => "ok",
             "messages" => [%{"role" => "user"}, %{"role" => "assistant"}]
           } = snapshot

    assert snapshot["sequence"] == Agent.snapshot(agent).sequence
    assert snapshot["conversation"]["id"] == "#{key}/#{Agent.snapshot(agent).generation}"

    assert {:ok, %{status: 404}} = Req.get(api, url: "/v1/agents/test/nobody")
  end

  describe "keys" do
    test "a user's agent is reached under @user, with every route after it", %{api: api} do
      name = "mine-#{System.unique_integer([:positive])}"
      tenant = tenant(api)

      {key, _agent} =
        Fleet.start_agent(
          [runner: {AgentRunners, :echo, [self(), "ok"]}],
          Wardrik.AgentID.parse!("test/@jon/#{name}")
        )

      text = to_string(key)

      assert {:ok, %{status: 200, body: %{"agent" => %{"id" => ^text}}}} =
               Req.get(tenant, url: "/v1/agents/test/@jon/#{name}")

      assert {:ok, %{status: 200, body: %{"agent" => %{"id" => ^text}}}} =
               Req.get(tenant, url: "/v1/agents/test/%40jon/#{name}")

      assert {:ok, %{status: 202}} =
               Req.post(tenant, url: "/v1/agents/#{key}/messages", json: %{"content" => "hi"})

      assert_receive {:turn, [{:user, "From tenant (token " <> _rest = said}]}
      assert said =~ ~r/\):\nhi$/

      assert {:ok, %{status: 404}} = Req.get(tenant, url: "/v1/agents/test/@ann/#{name}")
      assert {:ok, %{status: 404}} = Req.get(api, url: "/v1/agents/test/@jon/#{name}")
    end

    defp tenant(api) do
      {:ok, secret, _token} =
        Token.create(store(), "tenant",
          scope: Prefix.tenant!("test"),
          can: Grant.actions(),
          ceiling: []
        )

      Req.merge(api, auth: {:bearer, secret})
    end

    test "a path that is not an agent's ID is refused, and one past it is no route", %{api: api} do
      for path <- ["/v1/agents/test/@jon", "/v1/agents/_test/x", "/v1/agents/test/_x"] do
        assert {:ok, %{status: 400, body: body}} = Req.get(api, url: path)
        assert body["error"]["message"] =~ "is not an agent ID"
      end

      {key, _agent} = echo_agent()

      assert {:ok, %{status: 404, body: body}} = Req.get(api, url: "/v1/agents/#{key}/nothing")
      assert body["error"]["message"] == "No such route: GET /v1/agents/#{key}/nothing"
      assert {:ok, %{status: 404}} = Req.get(api, url: "/v1/agents/test")
    end

    test "a token scoped to a user reaches that user's agents alone", %{api: api} do
      {:ok, secret, _token} =
        Token.create(store(), "jon-only",
          scope: Prefix.parse!("test/@jon/"),
          can: [:read],
          ceiling: []
        )

      jon = Req.merge(api, auth: {:bearer, secret})
      name = "scoped-#{System.unique_integer([:positive])}"

      {mine, _agent} = Fleet.start_agent([], Wardrik.AgentID.parse!("test/@jon/#{name}"))
      {org, _agent} = Fleet.start_agent([], Wardrik.AgentID.parse!("test/#{name}"))

      assert {:ok, %{status: 200}} = Req.get(jon, url: "/v1/agents/#{mine}")
      assert {:ok, %{status: 404}} = Req.get(jon, url: "/v1/agents/#{org}")
      assert {:ok, %{status: 200, body: %{"agents" => agents}}} = Req.get(jon, url: "/v1/agents")
      ids = Enum.map(agents, & &1["id"])
      assert to_string(mine) in ids
      refute to_string(org) in ids
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

      assert_receive {:turn, [{:user, "From router-test (token " <> _rest = said}]}
      assert said =~ ~r/\):\nhi$/

      assert {:ok, %{status: 202, body: %{"message" => %{"id" => id}}}} =
               Req.post(api, url: "/v1/agents/#{key}/messages", json: %{"content" => "again"})

      assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[0-9a-f]{4}-[0-9a-f]{12}$/
      assert_receive {:turn, [{:user, ^said}, {:assistant, "ok"}, {:user, again}]}
      assert again =~ ~r/\):\nagain$/
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

      {:ok, secret, _token} =
        Token.create(store(), "reader", scope: Prefix.parse!("test/"), can: [:read])

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
                 url: "/v1/agents/#{key}/decisions",
                 json: %{"decisions" => [%{"id" => "call_1", "decision" => "approve"}]}
               )

      assert body == %{"decisions" => [%{"id" => "call_1", "decision" => "approved"}]}
      assert_receive {:resumed, %{"call_1" => :approve}}

      assert_receive %Event{
        payload: %Event.CallDecided{call_id: "call_1", decision: :approve, by: by}
      }

      assert Wardrik.Principal.type(by) == :token
      assert Wardrik.Principal.id(by) == token.id

      assert {:ok, %{status: 409, body: %{"error" => %{"type" => "conflict"}}}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/decisions",
                 json: %{"decisions" => [%{"id" => "call_1", "decision" => "approve"}]}
               )
    end

    test "an approval carries the note given with it", %{api: api} do
      {key, _agent} = parked_agent()

      assert {:ok, %{status: 200, body: %{"decisions" => [%{"decision" => "approved"}]}}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/decisions",
                 json: %{
                   "decisions" => [
                     %{"id" => "call_1", "decision" => "approve", "note" => "Only staging."}
                   ]
                 }
               )

      assert_receive %Event{
        payload: %Event.CallDecided{call_id: "call_1", decision: {:approve, "Only staging."}}
      }
    end

    test "rejects a call, with the reason given", %{api: api} do
      {key, _agent} = parked_agent()

      assert {:ok, %{status: 400}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/decisions",
                 json: %{"decisions" => [%{"id" => "call_1", "decision" => "maybe"}]}
               )

      assert {:ok, %{status: 409}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/decisions",
                 json: %{"decisions" => [%{"id" => "call_9", "decision" => "reject"}]}
               )

      assert {:ok, %{status: 200, body: %{"decisions" => [%{"decision" => "rejected"}]}}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/decisions",
                 json: %{
                   "decisions" => [
                     %{"id" => "call_1", "decision" => "reject", "reason" => "Not this quarter."}
                   ]
                 }
               )

      assert_receive {:resumed, %{"call_1" => {:deny, "Not this quarter."}}}
    end

    test "says so when the agent cannot record the decision", %{api: api} do
      {key, _agent} = parked_agent()
      :ok = EventLog.usurp(key)

      assert {:ok, %{status: 503, body: %{"error" => %{"type" => "unavailable"}}}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/decisions",
                 json: %{"decisions" => [%{"id" => "call_1", "decision" => "reject"}]}
               )
    end
  end

  # The actor a change made through the API names: its token.
  defp actor(token), do: %{"type" => "token", "id" => token.id, "name" => "router-test"}

  test "cancel stops what the agent is doing", %{api: api, token: token} do
    {key, agent} =
      Fleet.start_agent(runner: {AgentRunners, :blocking, [self(), "ok"]}, grace: 10)

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    Agent.ask(agent, "wait")
    assert_receive {:turn, _messages, _turn}
    # A cancel reads the agent's status from the fleet, which hears of the
    # turn just after the runner does.
    Fleet.await_update(fn -> Wardrik.Fleet.lookup(key).status != :idle end)

    assert {:ok, %{status: 202}} = Req.post(api, url: "/v1/agents/#{key}/cancel")
    assert_receive %Event{payload: %Event.TurnInterrupted{}}
    assert Audit.about("agents/#{key}") == [{"agent.cancelled", actor(token)}]

    assert {:ok, %{status: 404}} = Req.post(api, url: "/v1/agents/test/nobody/cancel")
  end

  test "clearing the conversation empties it, and waits while a turn runs", %{
    api: api,
    token: token
  } do
    {key, agent} =
      Fleet.start_agent(runner: {AgentRunners, :blocking, [self(), "ok"]}, grace: 10)

    :ok = Event.Bus.subscribe(key)
    Agent.ask(agent, "wait")
    assert_receive {:turn, _messages, turn}

    assert {:ok, %{status: 409, body: %{"error" => %{"type" => "conflict"}}}} =
             Req.delete(api, url: "/v1/agents/#{key}/conversation")

    assert Audit.about("agents/#{key}") == []
    send(turn, :release)
    assert_receive %Event{payload: %Event.TurnFinished{}}

    assert {:ok, %{status: 204}} = Req.delete(api, url: "/v1/agents/#{key}/conversation")
    assert_receive %Event{payload: %Event.ContextCleared{dropped: 2}}
    assert Agent.get_context(agent).messages == []
    assert Audit.about("agents/#{key}") == [{"agent.cleared", actor(token)}]

    assert {:ok, %{status: 404}} = Req.delete(api, url: "/v1/agents/test/nobody/conversation")
  end

  describe "definitions" do
    defp define(api, key, body), do: Req.put(api, url: "/v1/agents/#{key}", json: body)

    defp defined_key do
      key = Fleet.id("defined")
      on_exit(fn -> Wardrik.Fleet.forget(key) end)
      key
    end

    test "start the agent they describe, then bring it to a new one", %{api: api, token: token} do
      key = defined_key()

      assert {:ok, %{status: 201, body: snapshot}} = define(api, key, %{})
      text = to_string(key)

      assert %{
               "agent" => %{"id" => ^text},
               "status" => "idle",
               "request" => %{"model" => "claude-sonnet-5"}
             } = snapshot

      assert {:ok, %{status: 200, body: snapshot}} =
               define(api, key, %{"model" => "openai:gpt-5"})

      assert snapshot["request"]["model"] == "gpt-5"
      assert Agent.status(key).model == "openai:gpt-5"

      assert Audit.about("agents/#{key}") ==
               [{"agent.defined", actor(token)}, {"agent.defined", actor(token)}]
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
      key = Wardrik.AgentID.new!("defined-#{System.unique_integer([:positive])}", org: "other")

      assert {:ok, %{status: 404}} = define(api, key, %{})
      assert Wardrik.Fleet.lookup(key) == nil
    end

    test "for one agent never start another, and answer that something went wrong",
         %{api: api} do
      assert {:ok, %{status: 500, body: body}} =
               define(api, defined_key(), %{"elsewhere" => true})

      assert body["error"]["type"] == "internal"
      assert Wardrik.Fleet.lookup(Wardrik.AgentID.parse!("test/elsewhere")) == nil
    end

    test "for a key the module refuses start nothing", %{api: api} do
      key = defined_key()

      assert {:ok, %{status: 409, body: body}} = define(api, key, %{"owned" => true})
      assert body["error"] == %{"type" => "conflict", "message" => "#{key} belongs to a file."}
      assert Wardrik.Fleet.lookup(key) == nil
    end

    test "are neither taken nor kept by a server with nothing to read them", %{api: api} do
      api = listener(api, host: Host.new(store: Wardrik.Test.store()))
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 501, body: body}} = define(api, defined_key(), %{})
      assert body["error"]["type"] == "not_supported"
      assert {:ok, %{status: 501}} = Req.get(api, url: "/v1/agents/#{key}/definition")

      assert {:ok, %{status: 200, body: %{"forgotten" => [_key]}}} =
               Req.delete(api, url: "/v1/agents/#{key}")

      assert Wardrik.Fleet.lookup(key) == nil
    end

    test "are not kept by a module that only reads them", %{api: api} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 501, body: body}} = Req.get(api, url: "/v1/agents/#{key}/definition")
      assert body["error"]["message"] == "This server does not keep agents' definitions."
    end
  end

  describe "a token's ceiling" do
    # A client of the same listener holding a token that defines under `ceiling`.
    defp ceiled(api, ceiling) do
      {:ok, secret, _token} =
        Token.create(store(), "ceiled",
          scope: Prefix.parse!("test/"),
          can: [:define],
          ceiling: ceiling
        )

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
    setup %{api: api} do
      %{kept: listener(api, host: Host.new(store: Wardrik.Test.store(), definitions: %Kept{}))}
    end

    test "answers one back as it was sent, and forgets it with its agent", %{
      kept: kept,
      token: token
    } do
      key = defined_key()
      definition = %{"model" => "openai:gpt-5"}

      assert {:ok, %{status: 201}} = define(kept, key, definition)

      assert {:ok, %{status: 200, body: %{"definition" => ^definition, "missing" => []} = body}} =
               Req.get(kept, url: "/v1/agents/#{key}/definition")

      conforms(body, "definition_read")

      assert {:ok, %{status: 200, body: %{"forgotten" => [_forgotten], "kept" => []}}} =
               Req.delete(kept, url: "/v1/agents/#{key}")

      assert Wardrik.Fleet.lookup(key) == nil
      assert {:ok, %{status: 404}} = Req.get(kept, url: "/v1/agents/#{key}/definition")
      assert {:ok, %{status: 404}} = Req.delete(kept, url: "/v1/agents/#{key}")

      assert Audit.about("agents/#{key}") ==
               [{"agent.defined", actor(token)}, {"agent.forgotten", actor(token)}]
    end

    test "forgets an agent it kept no definition for", %{kept: kept} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 200, body: %{"forgotten" => [_forgotten], "kept" => []}}} =
               Req.delete(kept, url: "/v1/agents/#{key}")

      assert Wardrik.Fleet.lookup(key) == nil
    end

    test "forgets an agent asleep, as one awake", %{kept: kept} do
      {key, _agent} = echo_agent()
      :ok = Wardrik.Fleet.stop(key)

      assert {:ok, %{status: 200, body: %{"forgotten" => [_forgotten], "kept" => []}}} =
               Req.delete(kept, url: "/v1/agents/#{key}")

      refute Wardrik.Fleet.stored?(key)
    end

    test "may refuse to delete an agent, which is left be", %{kept: kept} do
      {key, _agent} = Fleet.start_agent([], Fleet.id("kept-owned"))

      assert {:ok, %{status: 409}} = Req.delete(kept, url: "/v1/agents/#{key}")
      assert Wardrik.Fleet.lookup(key)
      assert Audit.about("agents/#{key}") == []
    end

    test "may refuse to change an agent's triggers", %{kept: kept} do
      key = Fleet.id("kept-owned")

      assert {:ok, %{status: 409, body: body}} =
               Req.put(kept,
                 url: "/v1/agents/#{key}/triggers/sweep",
                 json: %{"every" => "2h", "prompt" => "Look less."}
               )

      assert body["error"]["message"] == "#{key} belongs to a file."
      assert {:ok, %{status: 409}} = Req.delete(kept, url: "/v1/agents/#{key}/triggers/sweep")
    end
  end

  describe "triggers" do
    setup %{api: api} do
      kept = listener(api, host: Host.new(store: Wardrik.Test.store(), definitions: %Kept{}))
      key = Fleet.id("triggered")
      {:ok, %{status: 201}} = Req.put(kept, url: "/v1/agents/#{key}", json: %{})
      on_exit(fn -> Wardrik.Fleet.forget(key) end)
      %{kept: kept, key: key}
    end

    defp trigger(api, key, name, body),
      do: Req.put(api, url: "/v1/agents/#{key}/triggers/#{name}", json: body)

    test "are set in the agent's definition, then changed", %{kept: kept, key: key, token: token} do
      assert {:ok, %{status: 201, body: %{"trigger" => %{"name" => "sweep", "every" => "1h"}}}} =
               trigger(kept, key, "sweep", %{"every" => "1h", "prompt" => "Look."})

      assert {:ok, %{status: 200, body: %{"trigger" => %{"every" => "2h"}}}} =
               trigger(kept, key, "sweep", %{"every" => "2h", "prompt" => "Look."})

      assert {"trigger.set", actor(token)} in Audit.about("agents/#{key}")
    end

    test "that do not read, or are for an agent with no definition kept, are refused",
         %{kept: kept, key: key} do
      assert {:ok, %{status: 400, body: body}} =
               trigger(kept, key, "sweep", %{"refuse" => "every is not a time"})

      assert body["error"]["message"] == "every is not a time"

      assert {:ok, %{status: 404, body: body}} =
               trigger(kept, "test/nobody", "sweep", %{"every" => "30m", "prompt" => "Look."})

      assert body["error"]["message"] == "test/nobody has no definition kept."
    end

    test "are deleted, and one that is not there is not found", %{
      kept: kept,
      key: key,
      token: token
    } do
      {:ok, %{status: 201}} =
        trigger(kept, key, "sweep", %{"every" => "1d", "prompt" => "Look."})

      assert {:ok, %{status: 204}} = Req.delete(kept, url: "/v1/agents/#{key}/triggers/sweep")

      assert {:ok, %{status: 404, body: body}} =
               Req.delete(kept, url: "/v1/agents/#{key}/triggers/sweep")

      assert body["error"]["message"] == "#{key} has no trigger sweep."

      assert Audit.about("agents/#{key}") == [
               {"agent.defined", actor(token)},
               {"trigger.set", actor(token)},
               {"trigger.removed", actor(token)}
             ]
    end

    test "are not set where the server keeps no definitions", %{api: api, key: key} do
      assert {:ok, %{status: 501, body: body}} =
               trigger(api, key, "sweep", %{"every" => "1h", "prompt" => "Look."})

      assert body["error"]["message"] == "This server keeps no triggers."
      assert {:ok, %{status: 501}} = Req.delete(api, url: "/v1/agents/#{key}/triggers/sweep")
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
      :ok = Log.trim(store(), key, through: 2, before: DateTime.add(DateTime.utc_now(), 1, :day))

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

      for nobody <- ["test/nobody", "other/nobody"] do
        assert {:ok, %{status: 404}} =
                 Req.get(api,
                   url: "/v1/agents/#{nobody}/events",
                   headers: [{"accept", "text/event-stream"}]
                 )
      end
    end

    test "a stream opened from the head of a sleeping agent wakes it and follows it",
         %{api: api} do
      key = sleeping_agent()

      stream = open(api, key, [])
      :ok = Agent.ask(key, "again")

      assert {[{_id, "wardrik.message.created"} | _rest], stream} = frames(stream, 3)
      Req.cancel_async_response(stream.response)
    end
  end

  # An agent that answered once, then went to sleep.
  defp sleeping_agent do
    {key, agent} =
      Fleet.start_agent(runner: {AgentRunners, :echo, [self(), "ok"]}, idle_timeout: 50)

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    Agent.ask(agent, "hi")
    assert_receive %Event{payload: %Event.AgentStopped{reason: :idle}}, 2_000
    assert Fleet.await_update(fn -> Wardrik.Fleet.whereis(key, wake: false) == nil end)
    key
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

  describe "exports" do
    # A client for the same listener, holding a token of its own.
    defp client(api, scope, can) do
      {:ok, secret, _token} =
        Token.create(store(), "export-test", scope: scope, can: can, ceiling: [])

      Req.merge(api, auth: {:bearer, secret})
    end

    defp sources(events), do: events |> Enum.map(& &1["source"]) |> Enum.uniq() |> Enum.sort()

    test "read the logs the caller may read, from where the export was moved to", %{api: api} do
      user = "exp#{System.unique_integer([:positive])}"

      {first, _agent} =
        Fleet.start_agent([], Wardrik.AgentID.new!("first", org: "test", user: user))

      {second, _agent} =
        Fleet.start_agent([], Wardrik.AgentID.new!("second", org: "test", user: user))

      client = client(api, Prefix.parse!("test/@#{user}/"), [:read])

      assert {:ok, %{status: 200, body: %{"events" => events, "next" => next, "gaps" => []}}} =
               Req.get(client, url: "/v1/exports/feed")

      assert sources(events) == [
               "wardrik://local/agents/#{first}",
               "wardrik://local/agents/#{second}"
             ]

      assert {:ok, %{body: %{"events" => ^events}}} = Req.get(client, url: "/v1/exports/feed")

      assert {:ok, %{status: 204}} =
               Req.post(client, url: "/v1/exports/feed", json: %{"next" => next})

      assert {:ok, %{body: %{"events" => []}}} = Req.get(client, url: "/v1/exports/feed")

      # Another caller's export of the same name is its own.
      other = client(api, Prefix.parse!("test/@#{user}/"), [:read])
      assert {:ok, %{body: %{"events" => ^events}}} = Req.get(other, url: "/v1/exports/feed")

      assert {:ok, %{status: 204}} = Req.delete(client, url: "/v1/exports/feed")
      assert {:ok, %{body: %{"events" => ^events}}} = Req.get(client, url: "/v1/exports/feed")
    end

    test "read the audit for a caller that reaches every agent", %{api: api} do
      :ok =
        Wardrik.Audit.record(
          Wardrik.Audit,
          {:agent_cleared, Wardrik.AgentID.parse!("test/exported")},
          by: nil
        )

      client = client(api, Prefix.all(), [:read])

      assert {:ok, %{status: 200, body: %{"events" => [event]}}} =
               Req.get(client, url: "/v1/exports/audit?limit=1")

      assert event["source"] == "wardrik://local/audit"
    end

    test "refuse a name that is not one, a caller that may not read, and a next not answered",
         %{api: api} do
      assert {:ok, %{status: 400}} = Req.get(api, url: "/v1/exports/@feed")
      assert {:ok, %{status: 400}} = Req.get(api, url: "/v1/exports/feed?limit=0")

      assert {:ok, %{status: 403}} =
               Req.get(client(api, Prefix.parse!("test/"), [:message]), url: "/v1/exports/feed")

      assert {:ok, %{status: 400, body: body}} =
               Req.post(api, url: "/v1/exports/feed", json: %{"next" => "not a page"})

      assert body["error"]["message"] == "next is not one a page of this export answered"
      assert {:ok, %{status: 400}} = Req.post(api, url: "/v1/exports/feed", json: %{})
      assert {:ok, %{status: 404}} = Req.put(api, url: "/v1/exports/feed", json: %{})
    end
  end

  describe "connections" do
    defp as(api, scope, principal) do
      {:ok, secret, _token} =
        Token.create(store(), "connections",
          scope: Prefix.parse!(scope),
          can: Grant.actions(),
          ceiling: [],
          for: principal
        )

      Req.merge(api, auth: {:bearer, secret})
    end

    @jon Wardrik.Principal.new(:user, "jon")

    test "lists, connects and forgets the person's own, or with owner=org the org's",
         %{api: api} do
      jon = as(api, "test/*", @jon)

      assert {:ok, %{status: 200, body: %{"connections" => listed}}} =
               Req.get(jon, url: "/v1/connections")

      assert listed == [
               %{"provider" => "github", "held_by" => "person"},
               %{"provider" => "linear"}
             ]

      assert {:ok, %{status: 200, body: %{"connections" => [%{"provider" => "github"} | _]}}} =
               Req.get(jon, url: "/v1/connections?owner=org")

      assert {:ok, %{status: 200, body: %{"connected" => true}}} =
               Req.post(jon, url: "/v1/connections/github")

      assert {:ok, %{status: 200, body: %{"connected" => false, "authorization" => link}}} =
               Req.post(jon, url: "/v1/connections/linear")

      assert link == %{"url" => "https://auth.example.com/linear"}

      conforms(
        %{"provider" => "linear", "connected" => false, "authorization" => link},
        "connecting"
      )

      assert {:ok, %{status: 204}} = Req.delete(jon, url: "/v1/connections/github")

      assert Audit.about("secrets/github") |> List.last() ==
               {"secret.removed", %{"type" => "user", "id" => "jon"}}

      assert {:ok, %{status: 404}} = Req.delete(jon, url: "/v1/connections/linear")
      assert {:ok, %{status: 404}} = Req.post(jon, url: "/v1/connections/nothing")
    end

    test "are refused to a caller with no person, outside its org, or without define",
         %{api: api} do
      assert {:ok, %{status: 400, body: body}} = Req.get(api, url: "/v1/connections")
      assert body["error"]["message"] =~ "owner=org"
      assert {:ok, %{status: 200}} = Req.get(api, url: "/v1/connections?owner=org")
      assert {:ok, %{status: 400}} = Req.get(api, url: "/v1/connections?owner=someone")

      globex = as(api, "globex/*", @jon)

      assert {:ok, %{status: 200, body: %{"connections" => listed}}} =
               Req.get(globex, url: "/v1/connections")

      refute Enum.any?(listed, &Map.has_key?(&1, "held_by"))

      {:ok, secret, _token} =
        Token.create(store(), "reader",
          scope: Prefix.tenant!("test"),
          can: [:read],
          ceiling: [],
          for: @jon
        )

      reader = Req.merge(api, auth: {:bearer, secret})
      assert {:ok, %{status: 403}} = Req.post(reader, url: "/v1/connections/linear")
    end

    test "answer 501 where the host offers none", %{api: api} do
      jon = api |> listener(host: Host.new(store: Wardrik.Test.store())) |> as("test/*", @jon)

      assert {:ok, %{status: 501}} = Req.get(jon, url: "/v1/connections")
    end
  end

  describe "servers" do
    test "lists, adds and removes the person's own, or with owner=org the org's", %{api: api} do
      jon = as(api, "test/*", @jon)

      assert {:ok, %{status: 200, body: %{"servers" => [%{"name" => "docs"}]} = body}} =
               Req.get(jon, url: "/v1/servers")

      conforms(body, "servers")

      assert {:ok, %{status: 200, body: %{"servers" => []}}} =
               Req.get(jon, url: "/v1/servers?owner=org")

      docs = %{"name" => "docs", "url" => "https://docs.example/mcp", "auth" => %{"none" => %{}}}

      assert {:ok, %{status: 201, body: %{"server" => "docs", "connected" => true} = body}} =
               Req.post(jon, url: "/v1/servers", json: docs)

      conforms(body, "server_added")

      assert {:ok, %{status: 201, body: %{"connected" => false, "authorization" => link}}} =
               Req.post(jon, url: "/v1/servers", json: %{docs | "name" => "crm"})

      assert link == %{"url" => "https://auth.example.com/crm"}

      assert {:ok, %{status: 409}} =
               Req.post(jon, url: "/v1/servers", json: %{docs | "name" => "taken"})

      assert {:ok, %{status: 204}} = Req.delete(jon, url: "/v1/servers/docs")

      assert Audit.about("servers/test/@jon/docs") |> List.last() ==
               {"server.removed", %{"type" => "user", "id" => "jon"}}

      assert {:ok, %{status: 404}} = Req.delete(jon, url: "/v1/servers/nothing")
    end

    test "are refused a body without a name, and answer 501 where the host offers none",
         %{api: api} do
      jon = as(api, "test/*", @jon)

      assert {:ok, %{status: 400}} = Req.post(jon, url: "/v1/servers", json: %{"url" => "x"})

      none = api |> listener(host: Host.new(store: Wardrik.Test.store())) |> as("test/*", @jon)
      assert {:ok, %{status: 501}} = Req.get(none, url: "/v1/servers")
    end
  end

  describe "requests to a trigger" do
    setup %{api: api} do
      :persistent_term.put(Hooked, self())
      on_exit(fn -> :persistent_term.erase(Hooked) end)

      %{anyone: Req.merge(api, auth: nil)}
    end

    test "are let through with no credential, and handed on as they were sent",
         %{anyone: anyone} do
      assert {:ok, %{status: 202, body: %{"delivery" => %{"status" => "asked"}}}} =
               Req.post(anyone,
                 url: "/v1/hooks/test/@jon/triage/issues",
                 body: ~s({"action": "opened"}),
                 headers: [{"content-type", "application/json"}, {"idempotency-key", "d-1"}]
               )

      assert_receive {:delivered, key, "issues", headers, ~s({"action": "opened"})}
      assert to_string(key) == "test/@jon/triage"
      assert {"idempotency-key", "d-1"} in headers

      assert {:ok, %{status: 202, body: %{"delivery" => %{"status" => "seen"}}}} =
               Req.post(anyone, url: "/v1/hooks/test/triage/issues", body: "seen")
    end

    test "take a secret at the end of the path as the request's bearer", %{anyone: anyone} do
      assert {:ok, %{status: 202}} =
               Req.post(anyone, url: "/v1/hooks/test/@jon/triage/issues/s3cret", body: "{}")

      assert_receive {:delivered, key, "issues", headers, "{}"}
      assert to_string(key) == "test/@jon/triage"
      assert {"authorization", "Bearer s3cret"} in headers

      assert {:ok, %{status: 404}} =
               Req.post(anyone, url: "/v1/hooks/test/triage/issues/s3cret/more", body: "{}")
    end

    test "answer what the trigger refuses", %{anyone: anyone} do
      answers =
        for body <- ["forged", "busy", "nowhere"],
            do: Req.post(anyone, url: "/v1/hooks/test/triage/issues", body: body)

      assert Enum.map(answers, fn {:ok, response} -> response.status end) == [404, 503, 404]
      for {:ok, response} <- answers, do: conforms(response.body, "error")
    end

    test "are refused past a megabyte, or with no trigger in the path", %{anyone: anyone} do
      assert {:ok, %{status: 413, body: body}} =
               Req.post(anyone,
                 url: "/v1/hooks/test/triage/issues",
                 body: String.duplicate("a", 1_048_577)
               )

      conforms(body, "error")
      assert {:ok, %{status: 404}} = Req.post(anyone, url: "/v1/hooks/test/triage", body: "{}")
      assert {:ok, %{status: 401}} = Req.get(anyone, url: "/v1/agents")
      refute_received {:delivered, _key, _name, _headers, _body}
    end
  end

  describe "agents under a prefix" do
    setup %{api: api} do
      %{api: listener(api, host: Host.new(store: Wardrik.Test.store(), definitions: %Kept{}))}
    end

    defp under(org), do: Wardrik.AgentID.Prefix.new!(org: org)

    defp org_agents(names) do
      org = "fleet-#{System.unique_integer([:positive])}"

      {org,
       for(
         name <- names,
         do: elem(Fleet.start_agent([], Wardrik.AgentID.new!(name, org: org)), 0)
       )}
    end

    defp scoped(api, org, can \\ Grant.actions()) do
      {:ok, secret, _token} =
        Token.create(store(), "fleet", scope: under(org), can: can, ceiling: [])

      Req.merge(api, auth: {:bearer, secret})
    end

    test "are listed, to a caller who may read them, and refused to one who may not", %{api: api} do
      {org, [a, b]} = org_agents(["a", "b"])

      assert {:ok, %{status: 200, body: %{"agents" => agents}}} =
               Req.get(scoped(api, org), url: "/v1/agents", params: [prefix: "#{org}/"])

      assert Enum.map(agents, & &1["id"]) == [to_string(a), to_string(b)]

      assert {:ok, %{status: 403}} = Req.get(scoped(api, org, [:message]), url: "/v1/agents")

      assert {:ok, %{status: 404}} =
               Req.get(scoped(api, org), url: "/v1/agents", params: [prefix: "elsewhere/"])
    end

    test "show what a cancel or a removal would do with plan=true, and do nothing",
         %{api: api} do
      {org, [a]} = org_agents(["a"])
      fleet = scoped(api, org)

      assert {:ok, %{status: 200, body: %{"cancelling" => []}}} =
               Req.post(fleet, url: "/v1/agents/cancel", params: [prefix: "#{org}/", plan: true])

      assert {:ok, %{status: 200, body: %{"forgetting" => [text], "keeping" => []}}} =
               Req.delete(fleet, url: "/v1/agents", params: [prefix: "#{org}/", plan: true])

      assert text == to_string(a)
      assert Wardrik.Fleet.lookup(a)
    end

    test "are cancelled, and removed, where the request names them", %{api: api} do
      {org, [a]} = org_agents(["a"])
      fleet = scoped(api, org)

      assert {:ok, %{status: 400}} = Req.post(fleet, url: "/v1/agents/cancel")
      assert {:ok, %{status: 400}} = Req.delete(fleet, url: "/v1/agents")

      assert {:ok, %{status: 202, body: %{"cancelled" => []}}} =
               Req.post(fleet, url: "/v1/agents/cancel", params: [prefix: "#{org}/"])

      assert {:ok, %{status: 200, body: %{"forgotten" => [_a], "failed" => []}}} =
               Req.delete(fleet, url: "/v1/agents", params: [prefix: "#{org}/"])

      assert Wardrik.Fleet.lookup(a) == nil

      assert {:ok, %{status: 404}} =
               Req.delete(fleet, url: "/v1/agents", params: [prefix: "#{org}/"])
    end

    test "answer the calls they wait on a person for", %{api: api} do
      {key, _agent} = parked_agent()
      assert Fleet.await_update(fn -> Wardrik.Fleet.lookup(key).status == :parked end)

      assert {:ok, %{status: 200, body: %{"interrupts" => interrupts}}} =
               Req.get(api, url: "/v1/interrupts", params: [prefix: to_string(key)])

      assert [%{"id" => "call_1", "agent" => %{"id" => text}}] = interrupts
      assert text == to_string(key)
    end
  end

  describe "an agent's life" do
    defp root(api) do
      {:ok, secret, _token} =
        Token.create(store(), "root", scope: Prefix.all(), can: Grant.actions(), ceiling: [])

      Req.merge(api, auth: {:bearer, secret})
    end

    test "is stopped, keeping its conversation, and spawned again from the store", %{api: api} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 200, body: %{"stopped" => [_key]}}} =
               Req.post(api, url: "/v1/agents/#{key}/stop")

      assert %{asleep: true} = Wardrik.Fleet.lookup(key)

      assert {:ok, %{status: 200, body: %{"from" => "store", "agent" => %{"asleep" => false}}}} =
               Req.post(api, url: "/v1/agents/#{key}/spawn")

      assert {:ok, %{status: 404}} = Req.post(api, url: "/v1/agents/test/nobody/stop")
    end

    test "is placed on a node, and moved, only by a token over every agent", %{api: api} do
      {key, _agent} = echo_agent()
      here = to_string(node())

      assert {:ok, %{status: 403}} =
               Req.post(api, url: "/v1/agents/#{key}/move", json: %{"node" => here})

      assert {:ok, %{status: 200, body: %{"moving" => %{"to" => ^here}}}} =
               Req.post(root(api),
                 url: "/v1/agents/#{key}/move",
                 params: [plan: true],
                 json: %{"node" => here}
               )

      assert {:ok, %{status: 200, body: %{"from" => "running"}}} =
               Req.post(root(api), url: "/v1/agents/#{key}/spawn", json: %{"node" => here})

      assert {:ok, %{status: 400}} =
               Req.post(root(api),
                 url: "/v1/agents/#{key}/move",
                 json: %{"node" => "nowhere@nohost"}
               )
    end
  end

  describe "the deployment" do
    defp over_every_agent(api, can \\ Grant.actions()) do
      {:ok, secret, _token} =
        Token.create(store(), "deployment", scope: Prefix.all(), can: can, ceiling: [])

      Req.merge(api, auth: {:bearer, secret})
    end

    test "lists its nodes and their agents, to a token over every agent", %{api: api} do
      {_key, _agent} = echo_agent()
      here = to_string(node())

      assert {:ok, %{status: 403}} = Req.get(api, url: "/v1/deployment/nodes")

      assert {:ok, %{status: 200, body: %{"nodes" => [%{"name" => ^here}]} = body}} =
               Req.get(over_every_agent(api, [:read]), url: "/v1/deployment/nodes")

      conforms(body, "nodes")
    end

    test "reloads its definitions where the host reads them again", %{api: api} do
      assert {:ok, %{status: 403}} = Req.post(api, url: "/v1/deployment/reload")

      assert {:ok, %{status: 501}} =
               Req.post(over_every_agent(api), url: "/v1/deployment/reload")
    end

    test "pages its audit after a sequence number", %{api: api} do
      :ok = Wardrik.Audit.record(Wardrik.Audit, {:agents_reloaded, [node()]}, by: nil)
      reader = over_every_agent(api, [:read])

      assert {:ok, %{status: 403}} = Req.get(api, url: "/v1/deployment/audit")

      assert {:ok, %{status: 200, body: %{"changes" => [_ | _]}}} =
               Req.get(reader, url: "/v1/deployment/audit")

      last = String.to_integer(List.last(Wardrik.Test.Audit.all())["sequence"])

      assert {:ok, %{status: 200, body: %{"changes" => [%{"type" => "wardrik.agents.reloaded"}]}}} =
               Req.get(reader,
                 url: "/v1/deployment/audit",
                 params: [starting_after: last - 1, limit: 1]
               )

      assert {:ok, %{status: 400}} =
               Req.get(reader, url: "/v1/deployment/audit", params: [starting_after: "x"])
    end

    test "makes no tokens over HTTP", %{api: api} do
      assert {:ok, %{status: 404}} = Req.post(over_every_agent(api), url: "/v1/deployment/tokens")
    end
  end

  describe "the resources' schemas" do
    @resources ~w(agent agent_snapshot authorization decisions definition_read trigger trigger_definition export error connections connecting nodes)

    defp schema(name) do
      WardrikProtocol.dir()
      |> Path.join("#{name}.json")
      |> File.read!()
      |> JSON.decode!()
    end

    defp conforms(value, name) do
      root = JSV.build!(schema(name), resolver: WardrikProtocol.Resolver)
      assert {:ok, _} = JSV.validate(value, root)
    end

    test "take their examples" do
      for name <- @resources, example <- schema(name)["examples"], do: conforms(example, name)
    end

    test "describe the agents listed, and their snapshots idle and parked", %{api: api} do
      {idle, agent} = echo_agent()
      Agent.ask(agent, "hi")
      settled(agent)
      {parked, _agent} = parked_agent()

      asleep = sleeping_agent()

      {:ok, %{body: %{"agents" => agents}}} = Req.get(api, url: "/v1/agents")
      for listed <- agents, do: conforms(listed, "agent")

      assert %{"asleep" => true, "status" => "idle"} =
               listed = Enum.find(agents, &(&1["id"] == to_string(asleep)))

      refute Map.has_key?(listed, "node")

      for key <- [idle, parked] do
        {:ok, %{status: 200, body: snapshot}} = Req.get(api, url: "/v1/agents/#{key}")
        conforms(snapshot, "agent_snapshot")
      end

      # Other tests write logs by hand, so the page is of agents of its own.
      user = "schemas#{System.unique_integer([:positive])}"

      listed = Wardrik.AgentID.new!("listed", org: "test", user: user)
      :ok = Log.subscribe(listed)
      {_key, _agent} = Fleet.start_agent([], listed)
      # Its log holds its start once the start is delivered.
      assert_receive %Wardrik.Event.Log.Entry{sequence: 1}

      reader = client(api, Prefix.parse!("test/@#{user}/"), [:read])

      {:ok, %{status: 200, body: page}} = Req.get(reader, url: "/v1/exports/schemas")
      assert [_ | _] = page["events"]
      conforms(page, "export")
    end

    test "describe every error", %{api: api} do
      {key, agent} = echo_agent()
      Agent.ask(agent, "hi")
      settled(agent)
      :ok = Log.trim(store(), key, through: 2, before: DateTime.add(DateTime.utc_now(), 1, :day))

      {:ok, secret, _token} =
        Token.create(store(), "reader", scope: Prefix.parse!("test/"), can: [:read])

      answers = [
        Req.get(api, url: "/v1/agents", auth: nil),
        Req.get(api, url: "/v1/agents/test/nobody"),
        Req.post(api, url: "/v1/agents/#{key}/messages", json: %{}),
        Req.post(api,
          url: "/v1/agents/#{key}/decisions",
          json: %{"decisions" => [%{"id" => "x", "decision" => "approve"}]}
        ),
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
