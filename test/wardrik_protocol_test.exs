defmodule WardrikProtocolTest do
  use ExUnit.Case, async: true

  @event %{
    "specversion" => "1.0",
    "id" => "0199a3c2-5f1e-7c3a-9d2b-4e8f1a6b7c90",
    "source" => "wardrik://local/agents/acme/triage",
    "type" => "wardrik.tool_call.started",
    "subject" => "tool_calls/call_1",
    "time" => "2026-10-01T12:04:01.540213Z",
    "datacontenttype" => "application/json",
    "dataschema" => "urn:wardrik:schema:v1:tool_call.started",
    "traceparent" => "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
    "parentspanid" => "a3ce929d0e0e4736",
    "sequence" => "000000000042",
    "data" => %{
      "tool" => %{
        "name" => "linear__search_issues",
        "call" => %{"id" => "call_1", "arguments" => %{}}
      },
      "decided" => %{"by" => "default"}
    }
  }

  defp valid?(name, value),
    do: match?({:ok, _value}, JSV.validate(value, JSV.build!(WardrikProtocol.schema(name))))

  test "lists every event's type" do
    assert Enum.count(WardrikProtocol.types()) == 53
    assert "wardrik.run.started" in WardrikProtocol.types()

    assert WardrikProtocol.dataschema("wardrik.run.started") ==
             "urn:wardrik:schema:v1:run.started"
  end

  defp names do
    WardrikProtocol.dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.map(&Path.basename(&1, ".json"))
    |> List.delete("openapi")
  end

  test "builds every schema whole, with nothing left to resolve" do
    for name <- names() do
      schema = WardrikProtocol.schema(name)
      refute inspect(schema) =~ "$ref"
      assert %JSV.Root{} = JSV.build!(schema)
    end
  end

  test "takes an OAuth app it can find, signing in only with parameters of its own" do
    google = %{"name" => "google", "issuer" => "https://accounts.google.com"}

    for name <- ["provider_input", "provider", "providers", "server_input"],
        example <- WardrikProtocol.schema(name)["examples"],
        do: assert(valid?(name, example), name)

    assert valid?("provider_input", Map.put(google, "authorization_params", %{"prompt" => "x"}))
    refute valid?("provider_input", Map.put(google, "authorization_params", %{"scope" => "x"}))
    refute valid?("provider_input", %{"name" => "google", "client_id" => "app"})

    refute valid?(
             "provider_input",
             Map.put(google, "authorization_endpoint", "https://accounts.google.com/auth")
           )
  end

  test "signs in to a server with an OAuth app it names, or one it gives, never both" do
    server = %{"name" => "ads", "url" => "https://mcp.ads.example/mcp"}
    with_auth = &Map.put(server, "auth", %{"oauth" => &1})

    assert valid?("server_input", with_auth.(%{"provider" => "google"}))
    refute valid?("server_input", with_auth.(%{"provider" => "google", "client_id" => "app"}))
    refute valid?("server_input", with_auth.(%{"provider" => "google", "scopes" => ["read"]}))
  end

  test "says who holds each server and where it came from, and never its headers" do
    for name <- ["server", "servers"],
        example <- WardrikProtocol.schema(name)["examples"],
        do: assert(valid?(name, example), name)

    command = %{"owner" => "deployment", "name" => "git", "source" => "config", "auth" => "none"}
    assert valid?("server", command)
    refute valid?("server", Map.delete(command, "owner"))
    refute valid?("server", Map.put(command, "source", "inline"))
    refute valid?("server", Map.put(command, "headers", %{"authorization" => "Bearer x"}))

    assert %Wardrik.MCPServer{owner: "deployment", source: :config, url: nil} =
             Wardrik.MCPServer.from_json(command)
  end

  test "takes a webhook for an owner's notices, its secret only ever named" do
    ops = %{"name" => "ops", "url" => "https://hooks.acme.example/wardrik"}

    assert valid?("notify_target_input", Map.put(ops, "secret", %{"name" => "HOOK_SECRET"}))
    refute valid?("notify_target_input", Map.put(ops, "secret", "shh"))
    refute valid?("notify_target_input", Map.put(ops, "name", "slack:#ops"))
    refute valid?("notify_target_input", Map.put(ops, "module", "Wardrik.Notify.Room"))
    refute valid?("notify_target_input", Map.put(ops, "req_options", %{}))
    refute valid?("notify_target_input", Map.delete(ops, "url"))

    room = %{"owner" => "deployment", "name" => "pager", "source" => "config", "kind" => "room"}
    assert valid?("notify_target", room)
    refute valid?("notify_target", Map.put(room, "room", "#ops"))

    assert %Wardrik.NotifyTarget{owner: "acme", source: :runtime, secret: "OPS_HOOK_SECRET"} =
             Wardrik.NotifyTarget.from_json(
               hd(WardrikProtocol.schema("notify_target")["examples"])
             )
  end

  test "checks an event and its data" do
    assert valid?("cloudevent", @event)
    assert valid?("tool_call.started", @event["data"])

    refute valid?("cloudevent", Map.delete(@event, "traceparent"))
    refute valid?("tool_call.started", Map.delete(@event["data"], "decided"))
  end

  test "says which events are never kept" do
    live = Enum.filter(WardrikProtocol.types(), &WardrikProtocol.live?/1)

    assert Enum.sort(live) == [
             "wardrik.activity.changed",
             "wardrik.message.delta",
             "wardrik.reasoning.delta",
             "wardrik.subagent.progress",
             "wardrik.tool_call.progress"
           ]
  end

  test "reads the same schemas from its files as it compiled in" do
    for name <- ["cloudevent", "defs", "run.interrupted", "message.completed"] do
      assert WardrikProtocol.Inline.schema(WardrikProtocol.dir(), name) ==
               WardrikProtocol.schema(name)
    end
  end

  test "has its files where it says, and needs no recompiling while they stay" do
    refute WardrikProtocol.__mix_recompile__?()
    assert File.exists?(Path.join(WardrikProtocol.dir(), "cloudevent.json"))
  end

  test "checks each schema's examples against it" do
    for name <- names(),
        example <- Map.get(WardrikProtocol.schema(name), "examples", []) do
      assert valid?(name, example), "#{name}: #{inspect(example)}"
    end
  end

  describe "operations" do
    test "lists each once, by the operation id every surface names it by" do
      ids = Enum.map(WardrikProtocol.operations(), & &1.id)

      assert Enum.sort(ids) == ~w(
               agent.approve agent.ask agent.authorization agent.calls agent.cancel agent.clear
               agent.decide agent.define agent.definition agent.deny agent.events agent.forget
               agent.kill agent.move agent.read agent.runs agent.spawn agent.stop agent.timeline
               agent.trigger_remove agent.trigger_set agents.cancel agents.forget agents.list
               audit.list channel.deliver connections.connect connections.disconnect connections.list
               deployment.nodes deployment.reload events.head events.list hook.deliver
               hook.deliver_with_secret interrupts.list
               mcp_servers.add mcp_servers.list mcp_servers.remove
               notify_targets.add notify_targets.list notify_targets.remove
               providers.add providers.list providers.remove
             )

      assert WardrikProtocol.operation("agent.unknown") == nil
    end

    test "says where each is served, what it needs, and what it does" do
      assert %{
               method: "post",
               path: "/v1/agents/{agent}/messages",
               action: "agent.ask",
               effect: "change",
               subject: "agent",
               status: 202,
               stream: false,
               parameters: [%{name: "agent", in: "path"}]
             } = WardrikProtocol.operation("agent.ask")

      assert %{stream: true, output: %{"required" => ["events", "next"]}} =
               WardrikProtocol.operation("events.list")

      assert %{output: nil} = WardrikProtocol.operation("agent.cancel")

      for operation <- WardrikProtocol.operations() do
        assert operation.effect in ~w(read change destructive)
        assert operation.subject in ~w(agent agents channel deployment hook owner)
        assert is_binary(operation.action)

        for %{name: name, in: "path"} <- operation.parameters,
            do: assert(operation.path =~ "{#{name}}")
      end
    end

    test "takes its parameters and body as one input" do
      input = JSV.build!(WardrikProtocol.operation("agent.ask").input)

      assert {:ok, _input} = JSV.validate(%{"agent" => "acme/triage", "content" => "Hi"}, input)

      assert {:ok, _input} =
               JSV.validate(%{"agent" => "acme/@jon/triage", "content" => "Hi"}, input)

      assert {:ok, _input} =
               JSV.validate(%{"agent" => "acme/triage/C1-1696.1234", "content" => "Hi"}, input)

      assert {:ok, _input} =
               JSV.validate(%{"agent" => "acme/@jon/triage/1696.1234", "content" => "Hi"}, input)

      refute match?(
               {:ok, _input},
               JSV.validate(%{"agent" => "a/b/c/d", "content" => "Hi"}, input)
             )

      refute match?({:ok, _input}, JSV.validate(%{"content" => "Hi"}, input))
      refute match?({:ok, _input}, JSV.validate(%{"agent" => "acme", "content" => "Hi"}, input))

      refute match?(
               {:ok, _input},
               JSV.validate(%{"agent" => "acme/triage", "content" => "Hi", "parts" => []}, input)
             )

      events = JSV.build!(WardrikProtocol.operation("events.list").input)
      assert {:ok, _input} = JSV.validate(%{"agents" => ["acme/triage"], "limit" => 5}, events)
      refute match?({:ok, _input}, JSV.validate(%{"agents" => ["acme/*"]}, events))
      refute match?({:ok, _input}, JSV.validate(%{"resources" => ["acme/*"]}, events))
      refute match?({:ok, _input}, JSV.validate(%{"limit" => 501}, events))
      refute match?({:ok, _input}, JSV.validate(%{"unknown" => 1}, events))
    end

    test "builds every input and output whole" do
      for operation <- WardrikProtocol.operations(),
          schema <- [operation.input, operation.output],
          schema != nil do
        refute inspect(schema) =~ "$ref"
        assert %JSV.Root{} = JSV.build!(schema)
      end
    end

    test "reads the same operations from its files as it compiled in" do
      document = WardrikProtocol.Operations.document(WardrikProtocol.dir())

      assert document == WardrikProtocol.openapi()
      assert WardrikProtocol.Operations.build(document) == WardrikProtocol.operations()
    end

    test "keeps the whole document" do
      assert %{"openapi" => "3.1.0", "paths" => paths} = WardrikProtocol.openapi()
      assert Map.has_key?(paths, "/v1/agents/{agent}/messages")
    end
  end
end
