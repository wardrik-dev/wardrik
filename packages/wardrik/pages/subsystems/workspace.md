# Wardrik.Workspace

File tools for agents. Each agent's files are kept in a `Wardrik.Store`,
so they outlive the node.

With [Wardrik](https://hexdocs.pm/wardrik), configure these fields in an agent file:

```yaml
tools: [files]
context: [MEMORY.md]
workspace:
  shared:
    runbooks: agt_runbooks
    notes: {agent: agt_notes, mode: read}
```

## With WardrikCore

Run the example in a fresh IEx session. Set `ANTHROPIC_API_KEY` before starting IEx.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.10"}])

store = Wardrik.Store.ETS.new(name: MyApp.Store)
{:ok, _store} = Supervisor.start_link([{Wardrik.Store, store}], strategy: :one_for_one)

children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :rest_for_one)
tree = "agents/agt_triage"

WardrikCore.start_agent(
  agent_id: "agt_triage",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{Wardrik.Workspace, store: store, tree: tree}],
  middleware: [{Wardrik.Workspace.Context, store: store, tree: tree, files: ["MEMORY.md"]}]
)
```

- `Wardrik.Workspace` gives the agent `read_file`, `write_file`, `edit_file`, `list_files`,
  `search_files` and `delete_file`. See `Wardrik.Workspace.Tools`.
- `Wardrik.Workspace.Context` reads `MEMORY.md` into every turn.
- Paths are relative to the tree, as `notes/today.md`. Shared trees are under `shared/<name>/`.
- Replacing a file needs the version it was read at, so two writers never lose each other's work.

## Policies

Each call names its path or glob, so a policy can match it:

```yaml
allow: [write_file(notes/*)]
```

## License

Apache-2.0
