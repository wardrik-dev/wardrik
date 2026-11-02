defmodule WardrikWorkspace do
  @moduledoc """
  File tools for agents, kept in a `WardrikStore`.

  A `WardrikCore.Capability` that gives an agent six tools over a tree of files: `read_file`,
  `write_file`, `edit_file`, `list_files`, `search_files` and `delete_file`.

      tree = "agents/agt_triage"

      WardrikCore.start_agent(
        agent_id: "agt_triage",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{WardrikWorkspace, store: store, tree: tree}],
        middleware: [{WardrikWorkspace.Context, store: store, tree: tree, files: ["MEMORY.md"]}]
      )

  Use it when an agent should keep notes, or work on files with others.

  ## Options

    * `:store` - required. The `WardrikStore` the files are kept in.
    * `:tree` - required. The agent's own tree.
    * `:shared` - `WardrikWorkspace.Mount`s for trees shared with the agent. `[]` unless set.

  See `WardrikWorkspace.Tools` for each tool's arguments, and `WardrikWorkspace.Context` for
  reading files into every turn.
  """

  @behaviour WardrikCore.Capability

  @impl WardrikCore.Capability
  def tools(_context, opts),
    do: opts |> WardrikWorkspace.Spec.new() |> WardrikWorkspace.Tools.build()
end
