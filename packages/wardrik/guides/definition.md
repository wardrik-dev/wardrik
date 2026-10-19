# Definitions

An agent's definition for Wardrik: the keys of an agent file's
frontmatter, or of the body of `PUT /v1/agents/{id}`, read into the
`Wardrik.Agent.Spec` the agent runs on. The daemon reads its agent files and
the HTTP API's definitions through it, and a host that keeps definitions in
its own store reads them the same way.

What a definition may name, the host says in its `Wardrik.Host`, the tools
and tool sources it holds and the runtimes that read a definition's settings,
and in a context: its MCP servers, channels, notify targets and policies, and
the defaults every agent takes.

```elixir
host = Wardrik.Host.register(host, :tools, [{"search", MyApp.Search}])

context = %WardrikDefinition.Context{
  org: "acme",
  servers: [github: []],
  mcp: WardrikMCP
}

{:ok, id, fields} = WardrikDefinition.parse(File.read!("agents/triage.md"), "triage", context)

{:ok, spec} =
  WardrikDefinition.spec(fields, id,
    owner: id,
    context: context,
    source: {:file, "triage.md"},
    host: host
  )

{:ok, _pid} = Wardrik.Fleet.put(spec)
```

The keys a definition takes are read from `wardrik_protocol`'s
`agent_definition.json` as this compiles, so the schema and the reader name
the same keys.
