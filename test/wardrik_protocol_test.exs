defmodule WardrikProtocolTest do
  use ExUnit.Case, async: true

  @event %{
    "specversion" => "1.0",
    "id" => "0199a3c2-5f1e-7c3a-9d2b-4e8f1a6b7c90",
    "source" => "wardrik://local/agents/agt_01JF8X5RQ2",
    "agent" => "agt_01JF8X5RQ2",
    "conversation" => "C1-1696.1234",
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
    assert Enum.count(WardrikProtocol.types()) == 52
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
               audit.list channel.deliver
               deployment.nodes deployment.reload events.head events.list hook.deliver
               hook.deliver_with_secret interrupts.list
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
        assert operation.subject in ~w(agent agents channel deployment hook)
        assert is_binary(operation.action)

        for %{name: name, in: "path"} <- operation.parameters,
            do: assert(operation.path =~ "{#{name}}")
      end
    end

    test "gives the operations on a conversation its route" do
      assert %{
               path: "/v1/agents/{agent}/messages",
               conversation: "/v1/agents/{agent}/conversations/{conversation}/messages"
             } = WardrikProtocol.operation("agent.ask")

      assert %{conversation: "/v1/agents/{agent}/conversations/{conversation}"} =
               WardrikProtocol.operation("agent.clear")

      assert %{conversation: nil} = WardrikProtocol.operation("agent.define")

      for %{conversation: route} = operation <- WardrikProtocol.operations(), route != nil do
        assert String.replace(route, "/conversations/{conversation}", "") == operation.path or
                 operation.id == "agent.clear"

        assert Map.has_key?(operation.input["properties"], "conversation")
      end
    end

    test "takes a hook's or channel's request as it came over HTTP" do
      paths = WardrikProtocol.openapi()["paths"]

      for {path, id} <- [
            {"/v1/hooks/{agent}/{trigger}", "hook.deliver"},
            {"/v1/hooks/{agent}/{trigger}/{secret}", "hook.deliver_with_secret"},
            {"/v1/channels/{channel}/{path}", "channel.deliver"}
          ] do
        assert %{"content" => %{"*/*" => %{}}} = paths[path]["post"]["requestBody"]
        input = JSV.build!(WardrikProtocol.operation(id).input)
        request = %{"body" => "{}", "headers" => %{"content-type" => "application/json"}}
        assert {:ok, _input} = JSV.validate(Map.merge(request, path_input(id)), input)
      end

      assert %{"content" => %{"*/*" => %{}}} =
               paths["/v1/channels/{channel}/{path}"]["post"]["responses"]["200"]

      assert %{output: %{"required" => ["status", "headers", "body"]}} =
               WardrikProtocol.operation("channel.deliver")
    end

    defp path_input("channel.deliver"), do: %{"channel" => "slack", "path" => "events"}
    defp path_input("hook.deliver"), do: %{"agent" => "agt_1", "trigger" => "gh"}

    defp path_input("hook.deliver_with_secret"),
      do: %{"agent" => "agt_1", "trigger" => "gh", "secret" => "s3cret"}

    test "takes its parameters and body as one input" do
      input = JSV.build!(WardrikProtocol.operation("agent.ask").input)

      for agent <- ["agt_01JF8X5RQ2", "acme/@jon/triage", "user 42's notes", "é"] do
        assert {:ok, _input} = JSV.validate(%{"agent" => agent, "content" => "Hi"}, input)
      end

      assert {:ok, _input} =
               JSV.validate(
                 %{"agent" => "agt_1", "conversation" => "C1-1696.1234", "content" => "Hi"},
                 input
               )

      for agent <- ["", "a\nb", String.duplicate("a", 256)] do
        refute match?({:ok, _input}, JSV.validate(%{"agent" => agent, "content" => "Hi"}, input))
      end

      refute match?(
               {:ok, _input},
               JSV.validate(%{"agent" => "agt_1", "conversation" => "", "content" => "Hi"}, input)
             )

      refute match?({:ok, _input}, JSV.validate(%{"content" => "Hi"}, input))

      refute match?(
               {:ok, _input},
               JSV.validate(%{"agent" => "agt_1", "content" => "Hi", "parts" => []}, input)
             )

      events = JSV.build!(WardrikProtocol.operation("events.list").input)
      assert {:ok, _input} = JSV.validate(%{"agents" => ["agt_1"], "limit" => 5}, events)
      refute match?({:ok, _input}, JSV.validate(%{"agents" => [""]}, events))
      refute match?({:ok, _input}, JSV.validate(%{"conversation" => "C1"}, events))
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
