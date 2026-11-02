# WardrikWorkspace

File tools for agents. Each agent gets a tree of files kept in a
[WardrikStore](https://hexdocs.pm/wardrik_store), so its files outlive the node. Agents can also
share trees, and have files read into every turn.

With [Wardrik](https://hexdocs.pm/wardrik), name `files` in the agent's tools and `context` in its
definition:

```yaml
tools: [files]
context: [MEMORY.md]
workspace:
  shared:
    team: acme                                  # read and written
    runbooks: {tree: acme/runbooks, mode: read} # read only
```

## Install

```elixir
def deps do
  [
    {:wardrik_workspace, "~> 0.1.0-rc.1"}
  ]
end
```

## With WardrikCore alone

Add `WardrikWorkspace` as a capability for the file tools. Add `WardrikWorkspace.Context` as
middleware to read files into every turn.

```elixir
store = WardrikStore.ETS.new(name: MyApp.Store)
tree = "agents/agt_triage"

WardrikCore.start_agent(
  agent_id: "agt_triage",
  model: "anthropic:claude-haiku-4-5",
  capabilities: [{WardrikWorkspace, store: store, tree: tree}],
  middleware: [{WardrikWorkspace.Context, store: store, tree: tree, files: ["MEMORY.md"]}]
)
```

## The file tools

| Tool | What it does |
| --- | --- |
| `read_file` | Reads a file's lines, numbered, with its version |
| `write_file` | Writes a whole file, or appends to it with `append` |
| `edit_file` | Replaces text that appears once, or everywhere with `all` |
| `list_files` | Lists the files a glob matches, newest first |
| `search_files` | Finds the lines a regular expression matches |
| `delete_file` | Deletes a file |

Paths are relative to the top of the tree, as `notes/2026-10-01.md`. Trees shared with the agent
are under `shared/<name>/`.

Replacing a file takes the version it was read at. Two writers never lose each other's work.

A tool that fails answers `%{ok: false, error: %{code: ..., message: ...}}`. The turn carries on.

Each call names its path or glob as its resource, so a policy can match it:

```yaml
allow: [write_file(notes/*)]
```

See `WardrikWorkspace.Tools` for each tool's arguments and limits.

## Read into every turn

`WardrikWorkspace.Context` appends the `:files` to the agent's instructions as each turn begins.
It also lists the other files at the top of the tree and the trees shared with the agent.

It reads up to 16 KB unless `:max_bytes` is set. A file over its share is cut to its start and
end, and the agent is asked to rewrite it shorter.
