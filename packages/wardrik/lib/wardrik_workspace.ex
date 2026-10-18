defmodule WardrikWorkspace do
  @moduledoc """
  Files for agents: a workspace of their own, and trees they share, through
  six file tools, `read_file`, `write_file`, `edit_file`, `list_files`,
  `search_files` and `delete_file`.

  It is a `Wardrik.Tool` source, named with the agent's
  `WardrikWorkspace.Spec`:

      {:ok, spec} = WardrikWorkspace.Spec.new("acme/@jon/triage", %{"team" => "acme"})
      Wardrik.LLM.Config.new(tools: [{WardrikWorkspace, spec}])

  An agent file names it as `files`, and its shared trees under `workspace`:

      tools: [files, web_search]
      workspace:
        shared:
          team: acme                                 # shared/team, acme's tree
          runbooks: {tree: acme/runbooks, mode: read}

  A file is a `WardrikWorkspace.File` kept by the mount's
  `WardrikWorkspace.Backend`, `WardrikStore` by default, so an agent finds its
  files on whichever node holds it and after its node is lost. What each tool
  takes and answers is in `WardrikWorkspace.Tools`.

  ## Deciding a call

  A file tool's call acts on its path, so a policy names it by what it acts
  on (see `c:Wardrik.Tool.subjects/2`), and a glob for `list_files` and
  `search_files`:

      allow: [read_file, list_files, write_file(notes/*)]
      deny: [delete_file(*)]

  No file tool is gated. Every one can run again after a lost node: a read
  changes nothing, and a change finds its own write.

  ## What it tells the agent first

  As each turn begins the workspace tells the agent what it holds: the files
  an agent file's `context` names, read in whole, the names of the others at
  the top of its tree, and the trees it shares. See `WardrikWorkspace.Context`.

      tools: [files]
      context: [SOUL.md]

  ## What a file holds

  A file records the `Wardrik.Label`s of what the runs that wrote it had
  read: an append or an edit keeps the labels the file had, and only a write
  that replaces the whole file takes its writer's alone. Reading it, or
  listing or finding it, labels the reader's run with them, so a finding a
  run left in a shared tree after reading content from outside carries that
  to every agent that reads it.
  """

  @behaviour Wardrik.Tool

  alias WardrikWorkspace.Context
  alias WardrikWorkspace.Path
  alias WardrikWorkspace.Spec
  alias WardrikWorkspace.Tools

  @doc "The six file tools over `spec`."
  @impl Wardrik.Tool
  def tools(%Spec{} = spec), do: Tools.build(spec)

  @doc "What a file tool's call acts on: its path, or the glob it lists or searches."
  @impl Wardrik.Tool
  def subjects(%Spec{}, name, arguments) when name in ["list_files", "search_files"] do
    key = if name == "list_files", do: "pattern", else: "glob"
    [Map.get(arguments, key) || "**"]
  end

  def subjects(%Spec{}, _name, %{"path" => path}) do
    case Path.normalize(path) do
      {:ok, path} -> [path]
      {:error, _message} -> []
    end
  end

  def subjects(%Spec{}, _name, _arguments), do: []

  @doc "What the workspace tells its agent as each turn begins; see `WardrikWorkspace.Context`."
  @impl Wardrik.Tool
  def context(%Spec{} = spec, %Wardrik.Run{host: host}), do: Context.text(spec, host)

  @doc "Every file tool may run again after a lost node."
  @impl Wardrik.Tool
  def annotations(%Spec{}, _name), do: %{in_doubt: :rerun}
end
