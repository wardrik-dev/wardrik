# WardrikProtocol

Wardrik's wire format: events as [CloudEvents](https://cloudevents.io), operations as one
[OpenAPI](https://spec.openapis.org/oas/v3.1.0) document, and typed Elixir functions like
`Wardrik.Agent.ask/4`.

## Install

```elixir
def deps do
  [
    {:wardrik_protocol, "~> 0.1.0-rc.4"}
  ]
end
```

## Check an event

`WardrikProtocol.schema/1` inlines every `$ref`, so any JSON Schema validator can use it. With
[JSV](https://hexdocs.pm/jsv):

```elixir
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
path  #=> "/v1/agents/{agent}/messages"
route #=> "/v1/agents/{agent}/conversations/{conversation}/messages"

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

```elixir
Wardrik.Agent.ask(scope, "agt_1", "Hi", conversation: "C1")
Wardrik.Agent.approve(scope, agent: "agt_1", interrupt: "call_1", conversation: "C1")
```

* An operation with one path parameter takes it as an argument, and `conversation:` in `opts`.
* An operation with two or more takes one keyword list, `conversation:` included. So does
  `Wardrik.Agent.decide/2`.
* An interrupt from `Wardrik.Agent.reply/4` or `Wardrik.Interrupts.list/2` names its agent and
  conversation: `Wardrik.Agent.approve(scope, interrupt: interrupt)`.
* An unknown key raises `ArgumentError`.
