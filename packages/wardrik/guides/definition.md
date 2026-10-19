# Definitions

An agent's definition for Wardrik: the keys of an agent file's frontmatter, or of the body of
`PUT /v1/agents/{id}`, read once into a `Wardrik.Definition`, which `Wardrik.Definitions` keeps in
the store and builds into the `Wardrik.Agent.Spec` the agent runs on each time it starts. The
daemon reads its agent files and the HTTP API's definitions through it, and an application that
embeds Wardrik keeps its agents' definitions the same way.

What a definition may name, the host says in its `Wardrik.Host`, the tools and tool sources it
holds and the runtimes that read a definition's settings, and in a context: its MCP servers and
policies, and the defaults every agent takes. A definition takes the defaults' `idle_timeout` and
`retries` as it is read; the policy and tools it names are found by their names each time its
agent starts.

```elixir
host = Wardrik.Host.register(host, :tools, [{"search", MyApp.Search}])

context = %WardrikDefinition.Context{
  org: "acme",
  servers: [github: []],
  mcp: WardrikMCP
}

{:ok, id, fields} = Wardrik.Definition.parse(File.read!("agents/triage.md"), "triage", context)

{:ok, definition} =
  Wardrik.Definition.read(fields, id: id, source: {:file, "agents/triage.md"}, context: context)

{:ok, spec} = Wardrik.Definition.spec(definition, id, context: context, host: host)
{:ok, _pid} = Wardrik.Fleet.put(spec)
```

The keys a definition takes are read from `wardrik_protocol`'s `agent_definition.json` as this
compiles, so the schema and the reader name the same keys.
