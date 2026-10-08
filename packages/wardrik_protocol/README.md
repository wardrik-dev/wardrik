# wardrik_protocol

The JSON Schemas of what [Wardrik](../wardrik) sends and takes: each event's
data, the CloudEvent that carries it, and the HTTP API's resources. Core writes
events to them, the HTTP API answers with them, and the
[TypeScript SDK](../../sdks/typescript)'s types are generated from them.

| File | What it describes |
| --- | --- |
| `priv/v1/<noun>.<verb>.json` | the data of a `wardrik.<noun>.<verb>` event |
| `priv/v1/cloudevent.json` | the envelope every event travels in |
| `priv/v1/defs.json` | the types events and resources share |
| the rest of `priv/v1` | one HTTP API resource each, such as `agent.json` |

Each schema's `$id` is `urn:wardrik:schema:v1:<file name>`, and an event's
`dataschema` names its data's.

```elixir
def deps do
  [{:wardrik_protocol, "~> 0.1.0", only: :test}]
end
```

```elixir
root = JSV.build!(%{"$ref" => "urn:wardrik:schema:v1:agent"}, resolver: WardrikProtocol.Resolver)
{:ok, _} = JSV.validate(agent, root)
```

A data path has one type across every event type, since Elasticsearch fixes
a field's type per index. Leave out `maxItems`: the TypeScript generator turns
it into a union of tuples.
