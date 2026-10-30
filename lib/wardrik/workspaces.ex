defmodule Wardrik.Workspaces do
  @moduledoc """
  Gives agents files: a tree of their own, shared trees, and files read into every turn.

  In a definition, `files` in `tools` adds the file tools, `context` lists files to read into
  every turn, and `workspace.shared` mounts shared trees:

      tools: [files]
      context: [MEMORY.md]
      workspace:
        shared:
          team: acme
          runbooks: {tree: acme/runbooks, mode: read}

  Trees are named `org`, `org/name` or `org/@user/name`. The owner the name starts with can mount
  it: acme's agents can mount `acme` and `acme/runbooks`, and jon's can mount `acme/@jon/notes`.

  Other agents can only mount a tree that Wardrik's `:workspace` option shares, by resource pattern:

      workspace: [shared: %{"acme/runbooks" => [read: ["acme/*"], write: ["acme/agent/ops", "acme/agent/ops/*"]]}]

  An agent's conversations share its tree.

  ## Context

  `context` lists at most 20 files. As a map, it takes `files` and `max_bytes`, from 1024 to
  262144. `max_bytes` is `16384` unless set.
  """

  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Resource
  alias WardrikEvents.Pattern
  alias WardrikWorkspace.Mount

  @max_files 20
  @bytes 1_024..262_144

  @doc """
  Returns the capabilities and middleware for the agent `id`'s workspace.

  Capabilities hold the file tools if `files?` is `true`. Middleware reads `context` into every
  turn. Returns an `invalid_request` error if the workspace or `context` is invalid.
  """
  @spec resolve(Wardrik.t(), String.t(), map(), boolean()) ::
          {:ok, [capabilities: list(), middleware: list()]} | {:error, Error.t()}
  def resolve(wardrik, id, definition, files?) do
    with {:ok, shared} <- shared(wardrik, id, get_in(definition, ["workspace", "shared"]) || %{}),
         {:ok, context} <- context(definition["context"]) do
      base = [store: wardrik.store, tree: tree(id), shared: shared]

      {:ok,
       [
         capabilities: if(files?, do: [{WardrikWorkspace, base}], else: []),
         middleware: if(context, do: [{WardrikWorkspace.Context, base ++ context}], else: [])
       ]}
    end
  end

  @doc "Returns the agent `id`'s own tree. A conversation uses its agent's."
  @spec tree(String.t()) :: String.t()
  def tree(id) do
    {:ok, resource} = id |> AgentID.agent() |> Resource.agent()
    "agents/" <> resource
  end

  @doc "Returns the `:workspace` option as each shared tree's read and write patterns."
  @spec settings(keyword() | nil) :: %{String.t() => %{read: [String.t()], write: [String.t()]}}
  def settings(nil), do: %{}

  def settings(opts) do
    for {tree, rule} <- Keyword.get(opts, :shared, %{}), into: %{} do
      {to_string(tree),
       %{read: Keyword.get(rule, :read, []), write: Keyword.get(rule, :write, [])}}
    end
  end

  defp shared(wardrik, id, shared) do
    mounts = Enum.map(shared, fn {name, mount} -> mount(wardrik, id, name, mount) end)

    case Enum.find(mounts, &match?({:error, _error}, &1)) do
      nil -> {:ok, Enum.map(mounts, fn {:ok, mount} -> mount end)}
      error -> error
    end
  end

  defp mount(wardrik, id, name, tree) when is_binary(tree),
    do: mount(wardrik, id, name, %{"tree" => tree})

  defp mount(wardrik, id, name, %{"tree" => tree} = mount) do
    mode = if mount["mode"] == "read", do: :read, else: :write

    with :ok <- named(name),
         :ok <- reached(wardrik, id, tree, mode),
         do: {:ok, %Mount{name: name, tree: "shared/" <> tree, mode: mode}}
  end

  defp named(name) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, name),
      do: :ok,
      else: invalid("A shared tree's name, #{inspect(name)}, is letters, digits, - and _.")
  end

  defp reached(wardrik, id, tree, mode) do
    {:ok, %AgentID{owner: owner}} = AgentID.parse(id)
    {:ok, resource} = Resource.agent(id)

    cond do
      owner(tree) == {:ok, owner} ->
        :ok

      shares?(Map.get(wardrik.workspace, tree), resource, mode) ->
        :ok

      true ->
        invalid(
          "#{id} can't #{mode} the tree #{tree}: it isn't its owner's, and the Wardrik doesn't share it so."
        )
    end
  end

  defp owner(tree) do
    case String.split(tree, "/") do
      [org] -> {:ok, org}
      [org, "@" <> _user = user, _name] -> {:ok, org <> "/" <> user}
      [org, name] when binary_part(name, 0, 1) != "@" -> {:ok, org}
      _other -> :error
    end
  end

  defp shares?(nil, _resource, _mode), do: false

  defp shares?(rule, resource, :read),
    do: Enum.any?(rule.read ++ rule.write, &Pattern.covers?(&1, resource))

  defp shares?(rule, resource, :write), do: Enum.any?(rule.write, &Pattern.covers?(&1, resource))

  defp context(nil), do: {:ok, nil}
  defp context(files) when is_list(files), do: context(%{"files" => files})

  defp context(%{"files" => files} = context) do
    bytes = Map.get(context, "max_bytes", 16_384)

    cond do
      length(files) > @max_files -> invalid("context names at most #{@max_files} files.")
      bytes not in @bytes -> invalid("context's max_bytes is from 1024 to 262144.")
      true -> {:ok, [files: files, max_bytes: bytes]}
    end
  end

  defp invalid(message), do: {:error, Error.new(:invalid_request, message)}
end
