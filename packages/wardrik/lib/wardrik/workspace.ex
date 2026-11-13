defmodule Wardrik.Workspace do
  @moduledoc """
  File tools for agents, kept in a `Wardrik.Store`.

  Application integration fragment. Start the required processes before calling these functions.
  See the [package README](https://hexdocs.pm/wardrik) for complete setup.

      WardrikCore.start_agent(
        agent_id: "agt_triage",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{Wardrik.Workspace, store: store, tree: "agents/agt_triage"}]
      )

  Gives `read_file`, `write_file`, `edit_file`, `list_files`, `search_files` and `delete_file`.
  See `Wardrik.Workspace.Tools`.

  ## Options

    * `:store` - required. The `Wardrik.Store` the files are kept in.
    * `:tree` - required. The agent's own tree.
    * `:shared` - `Wardrik.Workspace.Mount`s for trees shared with the agent. `[]` unless set.
  """

  @behaviour WardrikCore.Capability

  @impl WardrikCore.Capability
  def tools(_context, opts) do
    opts
    |> Wardrik.Workspace.Spec.new()
    |> Wardrik.Workspace.Tools.build()
  end
end
