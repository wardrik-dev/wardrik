# WardrikProtocol

Wardrik's wire format: events as [CloudEvents](https://cloudevents.io), operations as one
[OpenAPI](https://spec.openapis.org/oas/v3.1.0) document, and typed Elixir functions like
`Wardrik.Agent.ask/4`.

## Install

```elixir
def deps do
  [
    {:wardrik_protocol, "~> 0.1.0-rc.8"}
  ]
end
```

## Check an event

`WardrikProtocol.schema/1` inlines every `$ref`, so any JSON Schema validator can use it. With
[JSV](https://hexdocs.pm/jsv), in a fresh IEx session:

```elixir
Mix.install([{:wardrik_protocol, "~> 0.1.0-rc.8"}, {:jsv, "~> 0.26"}])

event = %{
  "specversion" => "1.0",
  "id" => "019a3c40-0000-7000-8000-000000000001",
  "source" => "wardrik://local/agents/agt_1",
  "type" => "wardrik.run.started",
  "subject" => "runs/run_1",
  "time" => "2026-11-06T12:00:00Z",
  "datacontenttype" => "application/json",
  "dataschema" => "urn:wardrik:schema:v1:run.started",
  "traceparent" => "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
  "data" => %{"run" => %{"id" => "0af7651916cd43dd8448eb211c80319c", "message_ids" => ["msg_1"]}}
}

envelope = JSV.build!(WardrikProtocol.schema("cloudevent"))
data = JSV.build!(WardrikProtocol.schema("run.started"))

{:ok, _event} = JSV.validate(event, envelope)
{:ok, _data} = JSV.validate(event["data"], data)
```

* Schemas are in `priv/v1`, one JSON file each. `run.started.json` is the `data` of
  `wardrik.run.started`.
* `WardrikProtocol.types/0` lists every event type.
* Live events, like `message.delta`, are never stored. Their schemas set `"x-wardrik-live": true`.

## Look up an operation

```elixir
%{path: path, conversation: route, input: input} = WardrikProtocol.operation("agent.ask")
path
# => "/v1/agents/{agent}/messages"

route
# => "/v1/agents/{agent}/conversations/{conversation}/messages"

{:ok, _input} = JSV.validate(%{"agent" => "agt_1", "content" => "Hi"}, JSV.build!(input))
```

* `openapi.json` names each operation by its `operationId`, like `agent.ask`. HTTP, the CLI and
  agents' tools use the same IDs.
* `input` is one schema for the path, query and body together.
* `x-wardrik-action` is what the caller must be allowed to do. `x-wardrik-effect` is `read`,
  `change` or `destructive`.
* Agent IDs are your app's: 1 to 255 characters, no control characters. In a route, `{agent}` is
  one URL-encoded segment.

## Call an operation

Create a scope with your running Wardrik runtime:

```elixir
scope = MyApp.AgentRuntime.as("maria")
Wardrik.Agent.ask(scope, "agt_1", "Hi", conversation: "C1")
Wardrik.Agent.approve(scope, agent: "agt_1", interrupt: "call_1", conversation: "C1")
```

- See [Run Wardrik](https://hexdocs.pm/wardrik/running-wardrik.html) for runtime setup.
- See `Wardrik.Agent` for parameter conventions and operation reference.
