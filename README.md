# WardrikProtocol

Wardrik's wire format: its events as [CloudEvents](https://cloudevents.io), and its operations as
one [OpenAPI](https://spec.openapis.org/oas/v3.1.0) document. It also holds the typed Elixir
functions, like `Wardrik.Agent.ask/3`, that packages built on Wardrik call.

## Install

```elixir
def deps do
  [
    {:wardrik_protocol, "~> 0.1.0-rc.2"}
  ]
end
```

## The schemas

Each schema is a JSON file in `priv/v1`. Its `$id` is `urn:wardrik:schema:v1:<file name>`.

| File | Describes |
| --- | --- |
| `<noun>.<verb>.json` | the `data` of the event `wardrik.<noun>.<verb>`, like `run.started.json` |
| `cloudevent.json` | the envelope every event is sent in |
| `defs.json` | types events share, like `message`, `principal` and `activity` |
| `openapi.json` | every operation, and its HTTP route |
| any other | an operation's input or output, like `ask.json` and `agent_snapshot.json` |

Live events are sent as they happen and never stored. Their schemas set `"x-wardrik-live": true`:
`activity.changed`, `message.delta`, `reasoning.delta`, `subagent.progress` and
`tool_call.progress`.

## Check an event

`WardrikProtocol.schema/1` returns a schema with every `$ref` inlined, so any JSON Schema validator
can use it without a resolver. With [JSV](https://hexdocs.pm/jsv):

```elixir
envelope = JSV.build!(WardrikProtocol.schema("cloudevent"))
data = JSV.build!(WardrikProtocol.schema("run.started"))

{:ok, _event} = JSV.validate(event, envelope)
{:ok, _data} = JSV.validate(event["data"], data)
```

`WardrikProtocol.types/0` lists every event type. `WardrikProtocol.dataschema/1` returns the
`dataschema` for a type.

## The operations

`openapi.json` defines each operation once, by its `operationId`, like `agent.ask`. The HTTP API,
the CLI and agents' tools all use the same IDs. Any OpenAPI 3.1 tool can read the file, so SDKs
are generated from it.

Each operation carries three extensions next to its HTTP route:

| Extension | Meaning | Example |
| --- | --- | --- |
| `x-wardrik-action` | what the caller must be allowed to do | `agent.ask` |
| `x-wardrik-effect` | `read`, `change` or `destructive` | `read` |
| `x-wardrik-subject` | what it acts on | `agent`, `agents`, `deployment` |

`WardrikProtocol.operations/0` lists them as maps. `WardrikProtocol.operation/1` finds one by ID.
Each has a single `input` schema that merges its path parameters, query parameters and body, so
surfaces other than HTTP see one set of named fields:

```elixir
%{input: input, output: output} = WardrikProtocol.operation("agent.ask")

{:ok, _input} = JSV.validate(%{"agent" => "agt_01JF8X5RQ2", "content" => "Hi"}, JSV.build!(input))
```

`parameters` lists which fields go in the HTTP path or query. The rest go in the body.

## Agents and conversations

Agent IDs are your app's: any text of 1 to 255 characters, without control characters. Wardrik
never reads anything from one. In a route, `{agent}` is one URL-encoded segment.

An agent can hold many conversations, each with its own history and events. An operation that
acts on one takes an optional `conversation`, and `conversation` names its route:

```elixir
%{path: path, conversation: route} = WardrikProtocol.operation("agent.ask")
path  #=> "/v1/agents/{agent}/messages"
route #=> "/v1/agents/{agent}/conversations/{conversation}/messages"
```

Events carry the `agent` and `conversation` attributes. A cursor lists each log it read, as
`[agent, conversation, sequence]`, in URL-safe base64 JSON.
