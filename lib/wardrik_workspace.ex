defmodule WardrikWorkspace do
  @moduledoc """
  File tools for agents, kept in a `WardrikStore`.

      WardrikCore.start_agent(
        agent_id: "agt_triage",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{WardrikWorkspace, store: store, tree: "agents/agt_triage"}]
      )

  Gives `read_file`, `write_file`, `edit_file`, `list_files`, `search_files` and `delete_file`.
  See `WardrikWorkspace.Tools`.

  ## Options

    * `:store` - required. The `WardrikStore` the files are kept in.
    * `:tree` - required. The agent's own tree.
    * `:shared` - `WardrikWorkspace.Mount`s for trees shared with the agent. `[]` unless set.
  """

  @behaviour WardrikCore.Capability

  @impl WardrikCore.Capability
  def tools(_context, opts),
    do: opts |> WardrikWorkspace.Spec.new() |> WardrikWorkspace.Tools.build()
end
