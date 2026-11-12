# Agent files

File tools for agents. Each agent's files are kept in Wardrik's store, so they outlive the node.
Give an agent these in its definition:

```yaml
tools: [files]
context: [MEMORY.md]
workspace:
  shared:
    runbooks: agt_runbooks
    notes: {agent: agt_notes, mode: read}
```

- `files` gives the agent `read_file`, `write_file`, `edit_file`, `list_files`, `search_files`
  and `delete_file`. See `Wardrik.Workspace.Tools`.
- `context` reads files into every turn.
- Paths are relative to the agent's files, as `notes/today.md`. Shared trees are under
  `shared/<name>/`. `mode: read` only reads one.
- Replacing a file needs the version it was read at, so two writers never lose each other's work.
- Your resolver can share workspaces too. See `Wardrik.Workspace.Agents`.

## Policies

Each call names its path or glob, so a policy can match it:

```yaml
allow: [write_file(notes/*)]
```

## With WardrikCore alone

```elixir
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

`Wardrik.Workspace` gives the tools, and `Wardrik.Workspace.Context` reads files into each turn.
The tree is where the agent's files are kept in the store.
