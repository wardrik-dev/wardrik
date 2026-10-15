# wardrik_definition

An agent's definition for [Wardrik](../wardrik): the keys of an agent file's
frontmatter, or of the body of `PUT /v1/agents/{id}`, read into the
`Wardrik.Agent.Spec` the agent runs on. The daemon reads its agent files and
the HTTP API's definitions through it, and a host that keeps definitions in
its own store reads them the same way.

```elixir
def deps do
  [{:wardrik_definition, "~> 0.1.0"}]
end
```

What a definition may name, the host says in a context: the tools it ships,
its MCP servers, channels, notify targets and policies, the defaults every
agent takes, and the seams every agent gets.

```elixir
context = %WardrikDefinition.Context{
  org: "acme",
  tools: [WardrikBrave.WebSearch],
  servers: [github: []],
  mcp: WardrikMCP,
  seams: [ledger: %Wardrik.Ledger.Store{}]
}

{:ok, id, fields} = WardrikDefinition.parse(File.read!("agents/triage.md"), "triage", context)
{:ok, spec, _route} = WardrikDefinition.spec(fields, id, id, context, {:file, "triage.md"})
{:ok, _pid} = Wardrik.Fleet.put(spec)
```

The keys a definition takes are read from `wardrik_protocol`'s
`agent_definition.json` as this compiles, so the schema and the reader name
the same keys.
