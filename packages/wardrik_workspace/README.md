# wardrik_workspace

Files for [Wardrik](../wardrik) agents: a workspace of each agent's own, and
trees they share, through six tools, `read_file`, `write_file`, `edit_file`,
`list_files`, `search_files` and `delete_file`.

```elixir
def deps do
  [{:wardrik_workspace, "~> 0.1.0"}]
end
```

```elixir
{:ok, spec} = WardrikWorkspace.Spec.new("acme/@jon/triage", %{"team" => "acme"})
Wardrik.LLM.Config.new(tools: [{WardrikWorkspace, spec}])
```

In the daemon, an agent file names it as `files`, and the trees it shares
under `workspace`:

```yaml
tools: [files, web_search]
context: [SOUL.md]
workspace:
  shared:
    team: acme                                  # shared/team, acme's tree
    runbooks: {tree: acme/runbooks, mode: read}
```

Files are kept in Wardrik's store with the agent, so it finds them on
whichever node holds it, and after its node is lost. A change is made over the
version last read, so two writers never lose each other's work.

As each turn begins, the agent is told what its workspace holds: the files
`context` names, read in whole, and the names of the others at the top of its
tree. A `MEMORY.md` it keeps there is something it finds in every turn without
filling its context.

A policy names a file tool's call by its path, as `write_file(notes/*)`. A file
remembers the labels of what the turns that wrote it had read, such as content
from outside, and reading it labels the reader's turn the same way.
