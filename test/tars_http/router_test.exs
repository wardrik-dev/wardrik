defmodule TarsHTTP.RouterTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Context
  alias Tars.Agent
  alias Tars.Agent.Spec
  alias Tars.Event
  alias Tars.Event.Log
  alias Tars.LLM.Config
  alias Tars.Schedule
  alias Tars.Test.AgentRunners
  alias Tars.Test.EventLog
  alias Tars.Test.Fleet
  alias TarsHTTP.Listener
  alias TarsHTTP.Token

  defmodule Definition do
    @moduledoc false
    @behaviour TarsHTTP.Definition

    @impl true
    def put(_key, %{"refuse" => message}), do: {:error, message}
    def put(key, %{"owned" => true}), do: {:error, :conflict, "#{key} belongs to a file."}
    def put(_key, %{"elsewhere" => true}), do: {:ok, Spec.new(name: "elsewhere", org: "test")}

    def put(key, fields) do
      {org, user, name} = Tars.Fleet.parse(key)
      config = Config.new(model_spec: Map.get(fields, "model", "anthropic:claude-sonnet-5"))
      {:ok, Spec.new(name: name, org: org, user: user, config: config, schedules: nil)}
    end
  end

  # Keeps what it is sent in Tars.Store, and refuses to delete a key that
  # ends in "-owned".
  defmodule Kept do
    @moduledoc false
    @behaviour TarsHTTP.Definition

    @ns :router_test_definitions

    @impl true
    def put(key, definition) do
      with {:ok, spec} <- Definition.put(key, definition),
           {:ok, _vsn} <- Tars.Store.put(@ns, key, definition),
           do: {:ok, spec}
    end

    @impl true
    def get(key) do
      case Tars.Store.get(@ns, key) do
        nil -> {:error, :not_found}
        definition -> {:ok, definition}
      end
    end

    @impl true
    def delete(key) do
      cond do
        String.ends_with?(key, "-owned") -> {:error, :conflict, "#{key} belongs to a file."}
        Tars.Store.get(@ns, key) == nil -> {:error, :not_found}
        true -> Tars.Store.delete(@ns, key)
      end
    end
  end

  setup do
    {:ok, secret, token} = Token.create("router-test", "test/")
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

  # A turn has finished, and the agent has written everything it emitted.
  defp settled(agent) do
    assert_receive %Event{payload: {:turn_finished, _messages}}
    Agent.status(agent)
  end

  describe "tokens" do
    test "a request without a token the API knows is refused", %{api: api} do
      for auth <- [nil, {:bearer, "tars_nope"}, {:basic, "user:pass"}] do
        assert {:ok, %{status: 401} = response} = Req.get(api, url: "/v1/agents", auth: auth)
        assert response.body["error"]["type"] == "unauthorized"
        assert Req.Response.get_header(response, "www-authenticate") == [~s(Bearer realm="tars")]
      end
    end

    test "a token for one agent lists that agent, and none whose key it begins", %{api: api} do
      {key, _agent} = Fleet.start_agent([], Fleet.key("scoped"))
      {longer, _agent} = Fleet.start_agent([], key <> "0")
      {:ok, secret, _token} = Token.create("one-agent", key)
      one = Req.merge(api, auth: {:bearer, secret})

      assert {:ok, %{status: 200, body: %{"agents" => [%{"id" => ^key}]}}} =
               Req.get(one, url: "/v1/agents")

      assert {:ok, %{status: 404}} = Req.get(one, url: "/v1/agents/#{longer}")
    end

    test "a path segment that holds a / is not a key segment", %{api: api} do
      {key, _agent} = echo_agent()
      [org, user, name] = String.split(key, "/")

      assert {:ok, %{status: 400, body: body}} =
               Req.get(api, url: "/v1/agents/#{org}/#{user}%2F#{name}/x")

      assert body["error"]["message"] ==
               ~s("#{user}/#{name}" holds a /; a key's org, user and name are a path segment each)
    end

    test "an agent outside the token's scope is one that does not exist", %{api: api} do
      {key, _agent} = Fleet.start_agent([], "other/_/hidden-#{System.unique_integer()}")

      assert {:ok, %{status: 404, body: body}} = Req.get(api, url: "/v1/agents/#{key}")
      assert body["error"]["message"] == "No agent runs under #{key}."

      {:ok, %{body: %{"agents" => agents}}} = Req.get(api, url: "/v1/agents")
      refute Enum.any?(agents, &(&1["id"] == key))
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

    assert {:ok, %{status: 404}} = Req.get(api, url: "/v1/agents/test/_/nobody")
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
               Req.post(api, url: "/v1/agents/test/_/nobody/messages", json: %{"content" => "hi"})
    end
  end

  describe "interrupts" do
    test "approves a call the agent is waiting on, in the token's name", %{api: api, token: token} do
      {key, _agent} = parked_agent()

      assert {:ok, %{status: 200, body: body}} =
               Req.post(api,
                 url: "/v1/agents/#{key}/interrupts/call_1",
                 json: %{"decision" => "approve"}
               )

      assert body == %{"interrupt" => %{"id" => "call_1", "decision" => "approved"}}
      assert_receive {:resumed, %{"call_1" => :approve}}

      assert_receive %Event{
        payload: {:call_decided, "call_1", :approve, %Tars.Principal{type: :token} = by}
      }

      assert by.id == token.id

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

    assert {:ok, %{status: 404}} = Req.post(api, url: "/v1/agents/test/_/nobody/cancel")
  end

  describe "definitions" do
    defp define(api, key, body), do: Req.put(api, url: "/v1/agents/#{key}", json: body)

    defp defined_key do
      key = Fleet.key("defined")
      on_exit(fn -> Tars.Fleet.forget(key) end)
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

      assert Tars.Fleet.lookup(key) == nil
    end

    test "outside the token's scope start nothing", %{api: api} do
      key = "other/_/defined-#{System.unique_integer([:positive])}"

      assert {:ok, %{status: 404}} = define(api, key, %{})
      assert Tars.Fleet.lookup(key) == nil
    end

    test "for one agent never start another", %{api: api} do
      key = defined_key()

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %{status: 500}} = define(api, key, %{"elsewhere" => true})
        end)

      assert log =~ "wrote a spec for test/_/elsewhere, not #{key}"
      assert Tars.Fleet.lookup("test/_/elsewhere") == nil
    end

    test "for a key the module refuses start nothing", %{api: api} do
      key = defined_key()

      assert {:ok, %{status: 409, body: body}} = define(api, key, %{"owned" => true})
      assert body["error"] == %{"type" => "conflict", "message" => "#{key} belongs to a file."}
      assert Tars.Fleet.lookup(key) == nil
    end

    test "are not taken, kept or deleted by a server with nothing to read them", %{api: api} do
      bare = listener(api, [])
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 501, body: body}} = define(bare, defined_key(), %{})
      assert body["error"]["type"] == "not_supported"
      assert {:ok, %{status: 501}} = Req.get(bare, url: "/v1/agents/#{key}/definition")
      assert {:ok, %{status: 501}} = Req.delete(bare, url: "/v1/agents/#{key}")
      assert Tars.Fleet.lookup(key)
    end

    test "are neither kept nor deleted by a module that only reads them", %{api: api} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 501, body: body}} = Req.get(api, url: "/v1/agents/#{key}/definition")
      assert body["error"]["message"] == "This server does not keep agents' definitions."
      assert {:ok, %{status: 501}} = Req.delete(api, url: "/v1/agents/#{key}")
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
      assert Tars.Fleet.lookup(key) == nil
      assert {:ok, %{status: 404}} = Req.get(kept, url: "/v1/agents/#{key}/definition")
      assert {:ok, %{status: 404}} = Req.delete(kept, url: "/v1/agents/#{key}")
    end

    test "forgets an agent it kept no definition for", %{kept: kept} do
      {key, _agent} = echo_agent()

      assert {:ok, %{status: 204}} = Req.delete(kept, url: "/v1/agents/#{key}")
      assert Tars.Fleet.lookup(key) == nil
    end

    test "leaves a stopped agent's store be, since none runs", %{kept: kept} do
      {key, _agent} = echo_agent()
      conversation = Agent.snapshot(key).generation
      :ok = Tars.Fleet.stop(key)

      assert {:ok, %{status: 404}} = Req.delete(kept, url: "/v1/agents/#{key}")

      {:ok, _pid} = Tars.Fleet.spawn(key)
      assert Agent.snapshot(key).generation == conversation
    end

    test "may refuse to delete an agent, which is left be", %{kept: kept} do
      {key, _agent} = Fleet.start_agent([], Fleet.key("kept") <> "-owned")

      assert {:ok, %{status: 409}} = Req.delete(kept, url: "/v1/agents/#{key}")
      assert Tars.Fleet.lookup(key)
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
               schedule(api, "test/_/nobody", "sweep", %{"every" => "30m", "prompt" => "Look."})

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

      assert Enum.map(events, & &1["type"]) == ["tars.message.created", "tars.run.started"]

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
                {"000000000002", "tars.message.created"},
                {"000000000003", "tars.run.started"},
                {"000000000004", "tars.run.completed"}
              ], stream} = frames(stream, 3)

      Agent.ask(agent, "again")

      assert {[
                {"000000000005", "tars.message.created"},
                {"000000000006", "tars.run.started"},
                {"000000000007", "tars.run.completed"}
              ], stream} = frames(stream, 3)

      Req.cancel_async_response(stream.response)
    end

    test "a stream with no cursor starts after the last event written", %{api: api} do
      {key, agent} = echo_agent()
      stream = open(api, key, [])

      Agent.ask(agent, "hi")

      assert {[{"000000000002", "tars.message.created"} | _rest], stream} = frames(stream, 3)
      Req.cancel_async_response(stream.response)

      assert {:ok, %{status: 404}} =
               Req.get(api,
                 url: "/v1/agents/test/_/nobody/events",
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

  defp parse(frame) do
    fields =
      for line <- String.split(frame, "\n"),
          [name, value] <- [String.split(line, ": ", parts: 2)],
          into: %{},
          do: {name, value}

    {fields["id"], JSON.decode!(fields["data"])["type"]}
  end
end
