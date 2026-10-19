defmodule WardrikHTTP.RouterTest do
  # The audit is one for the node, which these tests read.
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.Agent
  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Event
  alias Wardrik.Event.Log
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

    def put(_host, _key, %{"refuse" => message}, _token), do: {:error, message}

    def put(_host, key, %{"owned" => true}, _token),
      do: {:error, :conflict, "#{key} belongs to a file."}

    def put(_host, _key, %{"elsewhere" => true}, _token),
      do: {:ok, Spec.new(id: Wardrik.AgentID.parse!("test/elsewhere"))}

    # Holds the agent to a hook named for the policy its token names.
    def put(_host, key, %{"bounded" => true}, token) do
      bounded = [Wardrik.Hook.new(token.policy, Wardrik.Test.Tools.Rules, deny: :all)]
      {:ok, Spec.new(id: key, hooks: bounded)}
    end

    def put(_host, key, %{"allow" => names}, _token) do
      own = [Wardrik.Hook.new("own", Wardrik.Test.Tools.Rules, allow: names)]
      {:ok, Spec.new(id: key, hooks: own)}
    end

    def put(_host, key, fields, _token) do
      config = Config.new(model_spec: Map.get(fields, "model", "anthropic:claude-sonnet-5"))
      {:ok, Spec.new(id: key, config: config)}
    end
  end

  defimpl Wardrik.Definition, for: Definition do
    use Wardrik.Definition.None
    def put(d, key, opts), do: Definition.put(d, key, opts[:definition], opts[:token])
  end

  # Keeps what it is sent in WardrikStore, triggers beside definitions, and
  # refuses to change an agent whose name holds "-owned".
  defmodule Kept do
    @moduledoc false
    defstruct []

    @ns :router_test_definitions
    @triggers :router_test_triggers

    def put(host, key, definition, token) do
      with {:ok, spec} <- Definition.put(host, key, definition, token),
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
        case triggered(key, name) do
          nil ->
            {:error, :not_found}

          trigger ->
            :ok = WardrikStore.delete(store(), @triggers, "#{key}//#{name}")
            {:ok, trigger}
        end
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
    def put(d, key, opts), do: Kept.put(d, key, opts[:definition], opts[:token])
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
          {:ok,
           %WardrikHTTP.Caller{
             id: "session-#{user}",
             name: user,
             token: %Wardrik.Token{
               principal: Wardrik.Principal.new(:user, user),
               scope: [Wardrik.Role.bind([:owner], Prefix.parse!("test/"))]
             }
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
        %Wardrik.Connections.Connection{
          provider: "github",
          held_by: if(to_string(owner) == "test/@jon", do: :person)
        },
        %Wardrik.Connections.Connection{provider: "linear", held_by: nil}
      ]
    end

    def connect(_host, "github", %{name: "test/@jon"}, _by), do: {:ok, :held}

    def connect(_host, provider, _owner, _by) when provider in ["github", "linear"],
      do: {:ok, %{url: "https://auth.example.com/#{provider}", code: nil}}

    def connect(_host, _provider, _owner, _by), do: {:error, :not_found}

    def disconnect(_host, "github", %{name: "test/@jon"}), do: :ok
    def disconnect(_host, _provider, _owner), do: {:error, :not_found}
  end

  defimpl Wardrik.Connections, for: Linked do
    defdelegate list(c, owner), to: Linked
    defdelegate connect(c, provider, owner, opts), to: Linked
    defdelegate disconnect(c, provider, owner), to: Linked
  end

  # Has test/@jon's docs, adds docs and crm, the second behind a sign-in,
  # and has taken already.
  defmodule Added do
    @moduledoc false
    defstruct []

    def list(_servers, owner) do
      if to_string(owner) == "test/@jon",
        do: [%Wardrik.Servers.Server{name: "docs", url: "https://docs.example/mcp", auth: "none"}],
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

  # A token named `name`, made by a person of that name, holding `roles` over
  # `scope`: its secret, and the token as it is kept.
  defp token(name, scope, roles \\ [:owner], fields \\ []) do
    Token.create(store(), name,
      token:
        struct!(
          %Wardrik.Token{
            principal: Wardrik.Principal.new(:user, "ci", name: name),
            scope: [Wardrik.Role.bind(roles, scope)]
          },
          fields
        )
    )
  end

  setup do
    {:ok, secret, _token} = token("router-test", Prefix.parse!("test/"))

    listener = :"router-#{System.unique_integer([:positive])}"
    start_supervised!({Listener, name: listener, port: 0, host: host()})
    {:ok, port} = Listener.port(listener)

    %{
      api:
        [base_url: "http://127.0.0.1:#{port}", auth: {:bearer, secret}, retry: false]
        |> Req.new()
        |> WardrikHTTP.OpenAPI.attach()
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
        resumer:
          {AgentRunners, :resuming,
           [self(), {:ok, [Wardrik.Conversation.Assistant.new("shipped")]}]}
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

      {:ok, secret, _token} = token("one-agent", Prefix.of(key))

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

    test "an action the token does not allow is refused, and an agent out of reach is hidden",
         %{api: api} do
      {key, _agent} = echo_agent()

      {:ok, secret, _token} = token("watcher", Prefix.parse!("test/"), [:reader])

      watcher = Req.merge(api, auth: {:bearer, secret})

      assert {:ok, %{status: 200}} = Req.get(watcher, url: "/v1/agents/#{key}")

      assert {:ok, %{status: 403, body: body}} =
               Req.post(watcher, url: "/v1/agents/#{key}/messages", json: %{"content" => "hi"})

      assert body["error"] == %{
               "type" => "forbidden",
               "message" => "This token does not allow agent.ask on #{key}."
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

    test "an expired token is refused", %{api: api} do
      past = DateTime.add(DateTime.utc_now(), -1)
      {:ok, secret, _token} = token("expired", Prefix.parse!("test/"), [:owner], expires: past)

      assert {:ok, %{status: 401, body: body}} =
               Req.get(api, url: "/v1/agents", auth: {:bearer, secret})

      assert body["error"]["type"] == "unauthorized"
    end

    test "a revoked token is refused, and a stream open on it ends", %{api: api} do
      {key, _agent} = echo_agent()

      {:ok, secret, token} = token("revoked", Prefix.parse!("test/"))

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

      assert_receive {:turn, [{:user, "From tenant (user ci):" <> _rest = said}]}
      assert said =~ ~r/\):\nhi$/

      assert {:ok, %{status: 404}} = Req.get(tenant, url: "/v1/agents/test/@ann/#{name}")
      assert {:ok, %{status: 404}} = Req.get(api, url: "/v1/agents/test/@jon/#{name}")
    end

    defp tenant(api) do
      {:ok, secret, _token} = token("tenant", Prefix.tenant!("test"))

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
      {:ok, secret, _token} = token("jon-only", Prefix.parse!("test/@jon/"), [:reader])

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

      assert_receive {:turn, [{:user, "From router-test (user ci):" <> _rest = said}]}
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

      {:ok, secret, _token} = token("reader", Prefix.parse!("test/"), [:reader])

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

    test "approves a call the agent is waiting on, in the token's name", %{api: api} do
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

      assert by == Wardrik.Principal.new(:user, "ci", name: "router-test")

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

  # The actor a change made through the API names: whoever made its token.
  @actor %{"type" => "user", "id" => "ci", "name" => "router-test"}

  test "cancel stops what the agent is doing", %{api: api} do
    {key, agent} =
      Fleet.start_agent(runner: {AgentRunners, :blocking, [self(), "ok"]}, grace: 10)

    :ok = Event.Bus.subscribe(key, level: :lifecycle)
    Agent.ask(agent, "wait")
    assert_receive {:turn, _messages, _turn}
    # A cancel reads the agent's status from the fleet, which hears of the
    # turn just after the runner does.
    Fleet.await_update(fn ->
      Wardrik.Fleet.lookup(key, host: Wardrik.Test.host()).status != :idle
    end)

    assert {:ok, %{status: 202}} = Req.post(api, url: "/v1/agents/#{key}/cancel")
    assert_receive %Event{payload: %Event.TurnInterrupted{}}
    assert Audit.about("agents/#{key}") == [{"agent.cancelled", @actor}]

    assert {:ok, %{status: 404}} = Req.post(api, url: "/v1/agents/test/nobody/cancel")
  end

  test "clearing the conversation empties it, and waits while a turn runs", %{
    api: api
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

    assert {:ok, %{status: 200, body: %{"messages" => []} = cleared}} =
             Req.delete(api, url: "/v1/agents/#{key}/conversation")

    conforms(cleared, "agent_snapshot")
    assert_receive %Event{payload: %Event.ContextCleared{dropped: 2}}
    assert Agent.history(agent).messages == []
    assert Audit.about("agents/#{key}") == [{"agent.cleared", @actor}]

    assert {:ok, %{status: 404}} = Req.delete(api, url: "/v1/agents/test/nobody/conversation")
  end

  describe "definitions" do
    defp define(api, key, body), do: Req.put(api, url: "/v1/agents/#{key}", json: body)

    defp defined_key do
      key = Fleet.id("defined")
      on_exit(fn -> Wardrik.Fleet.forget(key) end)
      key
    end

    test "start the agent they describe, then bring it to a new one", %{api: api} do
      key = defined_key()

      assert {:ok, %{status: 200, body: snapshot}} = define(api, key, %{})
      text = to_string(key)

      assert %{
               "agent" => %{"id" => ^text},
               "status" => "idle",
               "request" => %{"model" => "claude-sonnet-5"}
             } = snapshot

      assert {:ok, %{status: 200, body: snapshot}} =
               define(api, key, %{"model" => "openai:gpt-5"})

      assert snapshot["request"]["model"] == "gpt-5"
      assert Agent.status(key, host: Wardrik.Test.host()).model == "openai:gpt-5"

      assert Audit.about("agents/#{key}") ==
               [{"agent.defined", @actor}, {"agent.defined", @actor}]
    end

    test "that do not read, or are not an object, start nothing", %{api: api} do
      key = defined_key()

      assert {:ok, %{status: 400, body: body}} = define(api, key, %{"refuse" => "model is text"})
      assert body["error"] == %{"type" => "invalid_request", "message" => "model is text"}

      assert {:ok, %{status: 400, body: body}} = define(api, key, ["model"])
      assert body["error"]["message"] == "The body is a JSON object"

      assert Wardrik.Fleet.lookup(key, host: Wardrik.Test.host()) == nil
    end

    test "outside the token's scope start nothing", %{api: api} do
      key = Wardrik.AgentID.new!("defined-#{System.unique_integer([:positive])}", org: "other")

      assert {:ok, %{status: 404}} = define(api, key, %{})
      assert Wardrik.Fleet.lookup(key, host: Wardrik.Test.host()) == nil
    end

    test "for one agent never start another, and answer that something went wrong",
         %{api: api} do
      assert {:ok, %{status: 500, body: body}} =
               define(api, defined_key(), %{"elsewhere" => true})

      assert body["error"]["type"] == "internal"

      assert Wardrik.Fleet.lookup(Wardrik.AgentID.parse!("test/elsewhere"),
               host: Wardrik.Test.host()
             ) == nil
    end

    test "for a key the module refuses start nothing", %{api: api} do
      key = defined_key()

      assert {:ok, %{status: 409, body: body}} = define(api, key, %{"owned" => true})
      assert body["error"] == %{"type" => "conflict", "message" => "#{key} belongs to a file."}
      assert Wardrik.Fleet.lookup(key, host: Wardrik.Test.host()) == nil
    end

    test "are neither taken nor kept by a server with nothing to read them", %{api: api} do
      api = listener(api, host: Host.new(store: Wardrik.Test.store()))
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 501, body: body}} = define(api, defined_key(), %{})
      assert body["error"]["type"] == "not_supported"
      assert {:ok, %{status: 501}} = Req.get(api, url: "/v1/agents/#{key}/definition")

      assert {:ok, %{status: 204}} = Req.delete(api, url: "/v1/agents/#{key}")

      assert Wardrik.Fleet.lookup(key, host: Wardrik.Test.host()) == nil
    end

    test "are not kept by a module that only reads them", %{api: api} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 501, body: body}} = Req.get(api, url: "/v1/agents/#{key}/definition")
      assert body["error"]["message"] == "This server does not keep agents' definitions."
    end
  end

  describe "a token's policy" do
    # The hooks the agent under `key` runs its calls past.
    defp hooks(key) do
      %{user_state: state} = :sys.get_state(Wardrik.Fleet.whereis(key, host: Wardrik.Test.host()))
      Keyword.fetch!(state.run_opts, :hooks)
    end

    test "goes by its name to the host's definitions, which hold the agent to it", %{api: api} do
      {:ok, secret, _token} = token("held", Prefix.parse!("test/"), [:definer], policy: "strict")
      key = defined_key()

      assert {:ok, %{status: 200}} =
               define(Req.merge(api, auth: {:bearer, secret}), key, %{"bounded" => true})

      assert [%Wardrik.Hook{name: "strict"}] = hooks(key)
    end
  end

  describe "a definition module that keeps definitions" do
    setup %{api: api} do
      %{kept: listener(api, host: Host.new(store: Wardrik.Test.store(), definitions: %Kept{}))}
    end

    test "answers one back as it was sent, and forgets it with its agent", %{
      kept: kept
    } do
      key = defined_key()
      definition = %{"model" => "openai:gpt-5"}

      assert {:ok, %{status: 200}} = define(kept, key, definition)

      assert {:ok, %{status: 200, body: %{"definition" => ^definition, "missing" => []} = body}} =
               Req.get(kept, url: "/v1/agents/#{key}/definition")

      conforms(body, "definition_read")

      assert {:ok, %{status: 204}} = Req.delete(kept, url: "/v1/agents/#{key}")

      assert Wardrik.Fleet.lookup(key, host: Wardrik.Test.host()) == nil
      assert {:ok, %{status: 404}} = Req.get(kept, url: "/v1/agents/#{key}/definition")
      assert {:ok, %{status: 404}} = Req.delete(kept, url: "/v1/agents/#{key}")

      assert Audit.about("agents/#{key}") ==
               [{"agent.defined", @actor}, {"agent.forgotten", @actor}]
    end

    test "forgets an agent it kept no definition for", %{kept: kept} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 204}} = Req.delete(kept, url: "/v1/agents/#{key}")

      assert Wardrik.Fleet.lookup(key, host: Wardrik.Test.host()) == nil
    end

    test "forgets an agent asleep, as one awake", %{kept: kept} do
      {key, _agent} = echo_agent()
      :ok = Wardrik.Fleet.stop(key)

      assert {:ok, %{status: 204}} = Req.delete(kept, url: "/v1/agents/#{key}")

      refute Wardrik.Fleet.stored?(key)
    end

    test "may refuse to delete an agent, which is left be", %{kept: kept} do
      {key, _agent} = Fleet.start_agent([], Fleet.id("kept-owned"))

      assert {:ok, %{status: 409}} = Req.delete(kept, url: "/v1/agents/#{key}")
      assert Wardrik.Fleet.lookup(key, host: Wardrik.Test.host())
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
      {:ok, %{status: 200}} = Req.put(kept, url: "/v1/agents/#{key}", json: %{})
      on_exit(fn -> Wardrik.Fleet.forget(key) end)
      %{kept: kept, key: key}
    end

    defp trigger(api, key, name, body),
      do: Req.put(api, url: "/v1/agents/#{key}/triggers/#{name}", json: body)

    test "are set in the agent's definition, then changed", %{kept: kept, key: key} do
      assert {:ok, %{status: 200, body: %{"trigger" => %{"name" => "sweep", "every" => "1h"}}}} =
               trigger(kept, key, "sweep", %{"every" => "1h", "prompt" => "Look."})

      assert {:ok, %{status: 200, body: %{"trigger" => %{"every" => "2h"}}}} =
               trigger(kept, key, "sweep", %{"every" => "2h", "prompt" => "Look."})

      assert {"trigger.set", @actor} in Audit.about("agents/#{key}")
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
      key: key
    } do
      {:ok, %{status: 200}} =
        trigger(kept, key, "sweep", %{"every" => "1d", "prompt" => "Look."})

      assert {:ok, %{status: 200, body: %{"trigger" => %{"name" => "sweep", "every" => "1d"}}}} =
               Req.delete(kept, url: "/v1/agents/#{key}/triggers/sweep")

      assert {:ok, %{status: 404, body: body}} =
               Req.delete(kept, url: "/v1/agents/#{key}/triggers/sweep")

      assert body["error"]["message"] == "#{key} has no trigger sweep."

      assert Audit.about("agents/#{key}") == [
               {"agent.defined", @actor},
               {"trigger.set", @actor},
               {"trigger.removed", @actor}
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
              ], stream} = kept(stream, 3)

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
      :ok = Agent.ask(key, "again", host: Wardrik.Test.host())

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
    assert Fleet.await_update(fn -> Wardrik.Fleet.held_pid(key, wake: false) == nil end)
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

  # The next `count` frames the log keeps, passing over live ones, such as
  # what the agent is doing.
  defp kept(stream, 0), do: {[], stream}

  defp kept(stream, count) do
    case frames(stream, 1) do
      {[{nil, _type}], stream} ->
        kept(stream, count)

      {[frame], stream} ->
        {frames, stream} = kept(stream, count - 1)
        {[frame | frames], stream}
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
    defp client(api, scope, roles) do
      {:ok, secret, _token} = token("export-test", scope, roles)
      Req.merge(api, auth: {:bearer, secret})
    end

    defp sources(events), do: events |> Enum.map(& &1["source"]) |> Enum.uniq() |> Enum.sort()

    test "read the logs the caller may read, from where the export was moved to", %{api: api} do
      user = "exp#{System.unique_integer([:positive])}"

      {first, _agent} =
        Fleet.start_agent([], Wardrik.AgentID.new!("first", org: "test", user: user))

      {second, _agent} =
        Fleet.start_agent([], Wardrik.AgentID.new!("second", org: "test", user: user))

      client = client(api, Prefix.parse!("test/@#{user}/"), [:reader])

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
      other = client(api, Prefix.parse!("test/@#{user}/"), [:reader])
      assert {:ok, %{body: %{"events" => ^events}}} = Req.get(other, url: "/v1/exports/feed")

      assert {:ok, %{status: 204}} = Req.delete(client, url: "/v1/exports/feed")
      assert {:ok, %{body: %{"events" => ^events}}} = Req.get(client, url: "/v1/exports/feed")
    end

    test "read the audit for a caller that owns every agent", %{api: api} do
      :ok =
        Wardrik.Audit.record(
          Wardrik.Audit,
          {:agent_cleared, Wardrik.AgentID.parse!("test/exported")},
          by: nil
        )

      client = client(api, Prefix.all(), [:owner])

      assert {:ok, %{status: 200, body: %{"events" => [event]}}} =
               Req.get(client, url: "/v1/exports/audit?limit=1")

      assert event["source"] == "wardrik://local/audit"
    end

    test "refuse a name that is not one, a caller that may not read, and a next not answered",
         %{api: api} do
      assert {:ok, %{status: 400}} = Req.get(api, url: "/v1/exports/@feed")
      assert {:ok, %{status: 400}} = Req.get(api, url: "/v1/exports/feed?limit=0")

      assert {:ok, %{status: 403}} =
               Req.get(client(api, Prefix.parse!("test/"), [:messenger]), url: "/v1/exports/feed")

      assert {:ok, %{status: 400, body: body}} =
               Req.post(api, url: "/v1/exports/feed", json: %{"next" => "not a page"})

      assert body["error"]["message"] == "next is not one a page of this export answered"
      assert {:ok, %{status: 400}} = Req.post(api, url: "/v1/exports/feed", json: %{})
      assert {:ok, %{status: 404}} = Req.put(api, url: "/v1/exports/feed", json: %{})
    end
  end

  describe "connections" do
    defp as(api, scope, principal, roles \\ [:owner]) do
      {:ok, secret, _token} =
        token("connections", Prefix.parse!(scope), roles, principal: principal)

      Req.merge(api, auth: {:bearer, secret})
    end

    @jon Wardrik.Principal.new(:user, "jon")

    test "lists, connects and forgets a person's own, or an org's", %{api: api} do
      jon = Req.merge(as(api, "test/*", @jon), params: [owner: "test/@jon"])

      assert {:ok, %{status: 200, body: %{"connections" => listed}}} =
               Req.get(jon, url: "/v1/connections")

      assert listed == [
               %{"provider" => "github", "held_by" => "person"},
               %{"provider" => "linear"}
             ]

      assert {:ok, %{status: 200, body: %{"connections" => [%{"provider" => "github"} | _]}}} =
               Req.get(jon, url: "/v1/connections", params: [owner: "test"])

      assert {:ok, %{status: 200, body: %{"connected" => true}}} =
               Req.post(jon, url: "/v1/connections/github")

      assert {:ok, %{status: 200, body: %{"connected" => false, "authorization" => link}}} =
               Req.post(jon, url: "/v1/connections/linear")

      assert link == %{"url" => "https://auth.example.com/linear"}

      conforms(
        %{"provider" => "linear", "connected" => false, "authorization" => link},
        "connecting"
      )

      assert {:ok,
              %{
                status: 200,
                body: %{"connection" => %{"provider" => "github", "held_by" => "person"}}
              }} =
               Req.delete(jon, url: "/v1/connections/github")

      assert Audit.about("secrets/github") |> List.last() ==
               {"secret.removed", %{"type" => "user", "id" => "jon"}}

      assert {:ok, %{status: 404}} = Req.delete(jon, url: "/v1/connections/linear")
      assert {:ok, %{status: 404}} = Req.post(jon, url: "/v1/connections/nothing")
    end

    test "are refused with no owner, outside the token's reach, or without definer",
         %{api: api} do
      assert {:ok, %{status: 400, body: body}} = Req.get(api, url: "/v1/connections")
      assert body["error"]["message"] =~ "owner"

      assert {:ok, %{status: 200}} =
               Req.get(api, url: "/v1/connections", params: [owner: "test"])

      for owner <- ["test/*", "test/agent/triage", "test/", "deployment", ""] do
        assert {:ok, %{status: 400}} =
                 Req.get(api, url: "/v1/connections", params: [owner: owner])
      end

      assert {:ok, %{status: 404}} =
               Req.post(api, url: "/v1/connections/github", params: [owner: "globex"])

      globex = as(api, "globex/*", @jon)

      assert {:ok, %{status: 200, body: %{"connections" => listed}}} =
               Req.get(globex, url: "/v1/connections", params: [owner: "globex/@jon"])

      refute Enum.any?(listed, &Map.has_key?(&1, "held_by"))

      reader = as(api, "test/*", @jon, [:reader])

      assert {:ok, %{status: 403}} =
               Req.post(reader, url: "/v1/connections/linear", params: [owner: "test/@jon"])
    end

    test "answer 501 where the host offers none", %{api: api} do
      jon = api |> listener(host: Host.new(store: Wardrik.Test.store())) |> as("test/*", @jon)

      assert {:ok, %{status: 501}} =
               Req.get(jon, url: "/v1/connections", params: [owner: "test/@jon"])
    end
  end

  describe "servers" do
    test "lists, adds and removes a person's own, or an org's", %{api: api} do
      jon = Req.merge(as(api, "test/*", @jon), params: [owner: "test/@jon"])

      assert {:ok, %{status: 200, body: %{"servers" => [%{"name" => "docs"}]} = body}} =
               Req.get(jon, url: "/v1/servers")

      conforms(body, "servers")

      assert {:ok, %{status: 200, body: %{"servers" => []}}} =
               Req.get(jon, url: "/v1/servers", params: [owner: "test"])

      docs = %{"name" => "docs", "url" => "https://docs.example/mcp", "auth" => %{"none" => %{}}}

      assert {:ok, %{status: 201, body: %{"server" => "docs", "connected" => true} = body}} =
               Req.post(jon, url: "/v1/servers", json: docs)

      conforms(body, "server_added")

      assert {:ok, %{status: 201, body: %{"connected" => false, "authorization" => link}}} =
               Req.post(jon, url: "/v1/servers", json: %{docs | "name" => "crm"})

      assert link == %{"url" => "https://auth.example.com/crm"}

      assert {:ok, %{status: 409}} =
               Req.post(jon, url: "/v1/servers", json: %{docs | "name" => "taken"})

      assert {:ok, %{status: 200, body: %{"server" => %{"name" => "docs", "auth" => "none"}}}} =
               Req.delete(jon, url: "/v1/servers/docs")

      assert Audit.about("servers/test/@jon/server/docs") |> List.last() ==
               {"server.removed", %{"type" => "user", "id" => "jon"}}

      assert {:ok, %{status: 404}} = Req.delete(jon, url: "/v1/servers/nothing")
    end

    test "are refused a body without a name, and answer 501 where the host offers none",
         %{api: api} do
      jon = Req.merge(as(api, "test/*", @jon), params: [owner: "test/@jon"])

      assert {:ok, %{status: 400}} = Req.post(jon, url: "/v1/servers", json: %{"url" => "x"})

      none = api |> listener(host: Host.new(store: Wardrik.Test.store())) |> as("test/*", @jon)

      assert {:ok, %{status: 501}} =
               Req.get(none, url: "/v1/servers", params: [owner: "test/@jon"])
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

    defp scoped(api, org, roles \\ [:owner]) do
      {:ok, secret, _token} = token("fleet", under(org), roles)
      Req.merge(api, auth: {:bearer, secret})
    end

    test "are listed, to a caller who may read them, and refused to one who may not", %{api: api} do
      {org, [a, b]} = org_agents(["a", "b"])

      assert {:ok, %{status: 200, body: %{"agents" => agents}}} =
               Req.get(scoped(api, org), url: "/v1/agents", params: [prefix: "#{org}/"])

      assert Enum.map(agents, & &1["id"]) == [to_string(a), to_string(b)]

      assert {:ok, %{status: 403}} = Req.get(scoped(api, org, [:messenger]), url: "/v1/agents")

      assert {:ok, %{status: 404}} =
               Req.get(scoped(api, org), url: "/v1/agents", params: [prefix: "elsewhere/"])
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

      assert Wardrik.Fleet.lookup(a, host: Wardrik.Test.host()) == nil

      assert {:ok, %{status: 404}} =
               Req.delete(fleet, url: "/v1/agents", params: [prefix: "#{org}/"])
    end

    test "answer the calls they wait on a person for", %{api: api} do
      {key, _agent} = parked_agent()

      assert Fleet.await_update(fn ->
               Wardrik.Fleet.lookup(key, host: Wardrik.Test.host()).status == :parked
             end)

      assert {:ok, %{status: 200, body: %{"interrupts" => interrupts}}} =
               Req.get(api, url: "/v1/interrupts", params: [prefix: to_string(key)])

      assert [%{"id" => "call_1", "agent" => %{"id" => text}}] = interrupts
      assert text == to_string(key)
    end
  end

  describe "an agent's life" do
    defp root(api) do
      {:ok, secret, _token} = token("root", Prefix.all())
      Req.merge(api, auth: {:bearer, secret})
    end

    test "is stopped, keeping its conversation, and spawned again from the store", %{api: api} do
      {key, _agent} = echo_agent()

      text = to_string(key)

      assert {:ok, %{status: 200, body: %{"agent" => %{"id" => ^text, "asleep" => true}}}} =
               Req.post(api, url: "/v1/agents/#{key}/stop")

      assert %{asleep: true} = Wardrik.Fleet.lookup(key, host: Wardrik.Test.host())

      assert {:ok, %{status: 200, body: %{"agent" => %{"asleep" => false}} = body}} =
               Req.post(api, url: "/v1/agents/#{key}/spawn")

      refute Map.has_key?(body, "from")

      assert {:ok, %{status: 404}} = Req.post(api, url: "/v1/agents/test/nobody/stop")
    end

    test "is placed on a node, and moved, only by a token over every agent", %{api: api} do
      {key, _agent} = echo_agent()
      here = to_string(node())

      assert {:ok, %{status: 403}} =
               Req.post(api, url: "/v1/agents/#{key}/move", json: %{"node" => here})

      assert {:ok, %{status: 200, body: %{"agent" => %{"node" => ^here}}}} =
               Req.post(root(api), url: "/v1/agents/#{key}/move", json: %{"node" => here})

      assert {:ok, %{status: 200, body: %{"agent" => %{"node" => ^here}}}} =
               Req.post(root(api), url: "/v1/agents/#{key}/spawn", json: %{"node" => here})

      assert {:ok, %{status: 400}} =
               Req.post(root(api),
                 url: "/v1/agents/#{key}/move",
                 json: %{"node" => "nowhere@nohost"}
               )
    end

    test "lists the tool calls it runs, and stops one", %{api: api} do
      {key, _agent} = echo_agent()
      test = self()

      hang =
        Wardrik.Tool.new!(
          name: "hang",
          description: "Waits.",
          run: fn _input, _context ->
            send(test, :started)
            receive do: (:never -> {:ok, %{}})
          end
        )

      run = Wardrik.Test.run(id: key, tools: [hang])
      spawn(fn -> Wardrik.Test.call(run, "hang", %{}, id: "call_1") end)
      assert_receive :started

      assert {:ok, %{status: 200, body: %{"calls" => [%{"id" => "call_1", "name" => "hang"}]}}} =
               Req.get(api, url: "/v1/agents/#{key}/calls")

      assert {:ok, %{status: 204}} = Req.delete(api, url: "/v1/agents/#{key}/calls/call_1")
      assert {:ok, %{status: 404}} = Req.delete(api, url: "/v1/agents/#{key}/calls/call_1")
      assert [{"call.killed", _by}] = Audit.about("agents/#{key}")
    end
  end

  describe "the deployment" do
    defp over_every_agent(api, roles \\ [:owner]) do
      {:ok, secret, _token} = token("deployment", Prefix.all(), roles)
      Req.merge(api, auth: {:bearer, secret})
    end

    test "lists its nodes and their agents, to a token owning every agent", %{api: api} do
      {_key, _agent} = echo_agent()
      here = to_string(node())

      assert {:ok, %{status: 403}} = Req.get(api, url: "/v1/deployment/nodes")

      assert {:ok, %{status: 403}} =
               Req.get(over_every_agent(api, [:reader]), url: "/v1/deployment/nodes")

      assert {:ok, %{status: 200, body: %{"nodes" => [%{"name" => ^here}]} = body}} =
               Req.get(over_every_agent(api), url: "/v1/deployment/nodes")

      conforms(body, "nodes")
    end

    test "reloads its definitions where the host reads them again", %{api: api} do
      assert {:ok, %{status: 403}} = Req.post(api, url: "/v1/deployment/reload")

      assert {:ok, %{status: 501}} =
               Req.post(over_every_agent(api), url: "/v1/deployment/reload")
    end

    test "pages its audit after a sequence number", %{api: api} do
      :ok = Wardrik.Audit.record(Wardrik.Audit, {:agents_reloaded, [node()]}, by: nil)
      reader = over_every_agent(api)

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
  end

  describe "tokens over HTTP" do
    setup %{api: api} do
      tokens = %WardrikHTTP.Tokens{store: store()}
      %{kept: listener(api, host: %{host() | tokens: tokens})}
    end

    @made %{
      "name" => "ci",
      "scope" => "test/",
      "roles" => ["reader", "messenger"],
      "policy" => "careful",
      "expires_in" => 3600
    }

    defp owning_every_agent(api) do
      {:ok, secret, _token} = token("root", Prefix.all())
      Req.merge(api, auth: {:bearer, secret})
    end

    test "are made, listed and revoked by a token owning every agent", %{kept: kept} do
      root = owning_every_agent(kept)

      assert {:ok, %{status: 403}} = Req.post(kept, url: "/v1/tokens", json: @made)
      assert {:ok, %{status: 403}} = Req.get(kept, url: "/v1/tokens")

      assert {:ok, %{status: 201, body: %{"token" => made, "secret" => secret} = issued}} =
               Req.post(root, url: "/v1/tokens", json: @made)

      conforms(issued, "token_issued")
      assert made["principal"] == %{"type" => "user", "id" => "ci", "name" => "root"}
      assert made["policy"] == "careful"

      assert made["statements"] == [
               %{
                 "actions" => Wardrik.Role.actions(:reader) ++ Wardrik.Role.actions(:messenger),
                 "resources" => ["test/"]
               }
             ]

      ci = Req.merge(kept, auth: {:bearer, secret})
      assert {:ok, %{status: 200}} = Req.get(ci, url: "/v1/agents")
      assert {:ok, %{status: 403}} = Req.get(ci, url: "/v1/tokens")

      assert {:ok, %{status: 200, body: %{"tokens" => tokens} = listed}} =
               Req.get(root, url: "/v1/tokens")

      conforms(listed, "tokens")
      assert made in tokens

      assert {:ok, %{status: 200, body: %{"token" => ^made}}} =
               Req.delete(root, url: "/v1/tokens/#{made["id"]}")

      assert {:ok, %{status: 401}} = Req.get(ci, url: "/v1/agents")
      assert {:ok, %{status: 404}} = Req.delete(root, url: "/v1/tokens/#{made["id"]}")
    end

    test "are refused a body that does not read", %{kept: kept} do
      root = owning_every_agent(kept)

      for body <- [
            %{},
            Map.delete(@made, "roles"),
            %{@made | "roles" => ["boss"]},
            %{@made | "roles" => "reader"},
            %{@made | "scope" => "not a prefix"},
            %{@made | "expires_in" => 0},
            %{@made | "policy" => ["careful"]}
          ] do
        assert {:ok, %{status: 400, body: %{"error" => %{"type" => "invalid_request"}}}} =
                 Req.post(root, url: "/v1/tokens", json: body)
      end
    end

    test "answer 501 where the host keeps none", %{api: api} do
      assert {:ok, %{status: 501}} = Req.get(owning_every_agent(api), url: "/v1/tokens")
    end
  end

  describe "the resources' schemas" do
    @resources ~w(agent agent_snapshot authorization decisions definition_read trigger trigger_definition export error connections connecting nodes input_tokens_create)

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

      reader = client(api, Prefix.parse!("test/@#{user}/"), [:reader])

      {:ok, %{status: 200, body: page}} = Req.get(reader, url: "/v1/exports/schemas")
      assert [_ | _] = page["events"]
      conforms(page, "export")
    end

    test "describe every error", %{api: api} do
      {key, agent} = echo_agent()
      Agent.ask(agent, "hi")
      settled(agent)
      :ok = Log.trim(store(), key, through: 2, before: DateTime.add(DateTime.utc_now(), 1, :day))

      {:ok, secret, _token} = token("reader", Prefix.parse!("test/"), [:reader])

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

  describe "a chat channel's requests" do
    @doc false
    def answering(test, request) do
      send(test, {:channel, request})
      %{status: 200, headers: [{"content-type", "text/plain"}], body: "taken"}
    end

    test "hands what the medium sends to its channel, as it was sent, and sends back its answer",
         %{api: api} do
      api = listener(api, channels: %{"chat" => {__MODULE__, :answering, [self()]}})

      assert {:ok, %{status: 200, body: "taken"}} =
               Req.post(Req.merge(api, auth: nil),
                 url: "/v1/channels/chat/events?retry=1",
                 headers: [{"x-signature", "v0=abc"}, {"content-type", "application/json"}],
                 body: ~s({"a": 1})
               )

      assert_received {:channel, request}

      assert %{method: "POST", path: ["events"], query: %{"retry" => "1"}, body: ~s({"a": 1})} =
               request

      assert {"x-signature", "v0=abc"} in request.headers
    end

    test "answers 404 for a channel that takes no requests here", %{api: api} do
      assert {:ok, %{status: 404, body: %{"error" => %{"message" => message}}}} =
               Req.post(Req.merge(api, auth: nil), url: "/v1/channels/elsewhere/events", body: "")

      assert message =~ "No channel elsewhere"
    end
  end

  describe "openapi.json" do
    @values %{
      "org" => "test",
      "user" => "jon",
      "name" => "nobody-openapi",
      "interrupt" => "call_1",
      "call" => "call_1",
      "trigger" => "sweep",
      "secret" => "s",
      "export" => "openapi",
      "provider" => "github",
      "server" => "docs",
      "channel" => "chat",
      "path" => "events",
      "token" => "0123456789ab"
    }

    # As a token over an org of its own, whose export reads no other test's
    # log.
    test "names every route the router serves, and no method it does not", %{api: api} do
      probe = scoped(api, "openapi-#{System.unique_integer([:positive])}")

      for {template, methods} <- WardrikHTTP.OpenAPI.routes(),
          method <- ~w(get put post delete) do
        path = Regex.replace(~r/\{([a-z_]+)\}/, template, fn _whole, name -> @values[name] end)

        {:ok, response} =
          Req.request(probe,
            method: String.to_atom(method),
            url: path,
            headers: [connection: "close"]
          )

        routed? = not match?(%{"error" => %{"message" => "No such route" <> _}}, response.body)

        assert routed? == method in methods,
               "#{String.upcase(method)} #{template} answered #{response.status}"
      end
    end
  end
end
