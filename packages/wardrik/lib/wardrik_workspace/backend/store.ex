defmodule WardrikWorkspace.Backend.Store do
  @moduledoc """
  A `Wardrik.Workspace` keeping every file a record in the store it holds,
  in the `:files` namespace under its tree and path, so a tree is wherever
  the store is, on every node, on EKV, Postgres or a bucket alike:

      Wardrik.Host.new(store: store, workspace: %WardrikWorkspace.Backend.Store{store: store})

      files / agents/acme/@jon/triage//MEMORY.md
      files / shared/acme//findings/2026-09-30-db-failover.md

  The `//` is where a tree ends and its path begins. A tree and a path are
  each some text with no empty part, as `WardrikWorkspace.Path` normalises
  them, so neither holds `//`, and the first one in a key is always the
  boundary. That is what keeps a tree apart from one named under it:
  `shared/acme//runbooks/x.md` is a file of `shared/acme`, and
  `shared/acme/runbooks//x.md` one of `shared/acme/runbooks`, where a single
  `/` would make them the same record. A tree or a path that is not
  normalised, one with an empty part, is refused as `{:error, {:not_a_tree,
  tree}}` or `{:error, {:not_a_path, path}}` rather than written where it
  could reach another tree's files.

  A file's version is the store's version of its record, and every change is
  a conditional write on that one key.
  """

  @enforce_keys [:store]
  defstruct [:store]

  @type t() :: %__MODULE__{store: WardrikStore.t()}

  alias WardrikWorkspace.File

  @ns :files
  @between "//"

  @doc false
  def read(%__MODULE__{store: store}, tree, path) do
    with {:ok, key} <- key(tree, path) do
      case WardrikStore.lookup(store, @ns, key) do
        {%File{} = file, version} -> {:ok, file, version}
        _none -> :none
      end
    end
  end

  @doc false
  def write(%__MODULE__{store: store}, tree, path, opts) do
    %File{} = file = Keyword.fetch!(opts, :file)

    with {:ok, key} <- key(tree, path),
         do: WardrikStore.put(store, @ns, key, file, if_vsn: Keyword.fetch!(opts, :version))
  end

  @doc false
  def delete(%__MODULE__{store: store}, tree, path, opts) do
    with {:ok, key} <- key(tree, path),
         do: WardrikStore.delete(store, @ns, key, if_vsn: Keyword.fetch!(opts, :version))
  end

  # Every key under `tree//` is this tree's, whatever `prefix` adds to it, so
  # only the tree needs to be normalised.
  @doc false
  def list(%__MODULE__{store: store} = workspace, tree, prefix) do
    with :ok <- normalised(tree, :not_a_tree) do
      root = tree <> @between

      files =
        for key <- WardrikStore.keys(store, @ns, root <> prefix),
            path = String.replace_prefix(key, root, ""),
            {:ok, file, version} <- [read(workspace, tree, path)],
            do: {path, file, version}

      {:ok, files}
    end
  end

  @doc false
  def paths(%__MODULE__{store: store}, tree, prefix) do
    with :ok <- normalised(tree, :not_a_tree) do
      root = tree <> @between

      {:ok,
       for(
         key <- WardrikStore.keys(store, @ns, root <> prefix),
         do: String.replace_prefix(key, root, "")
       )}
    end
  end

  defp key(tree, path) do
    with :ok <- normalised(tree, :not_a_tree),
         :ok <- normalised(path, :not_a_path),
         do: {:ok, tree <> @between <> path}
  end

  # No empty part: nothing blank, no `/` to begin or end it, and no `//`.
  defp normalised(name, refusal) do
    if is_binary(name) and "" not in String.split(name, "/"),
      do: :ok,
      else: {:error, {refusal, name}}
  end
end

defimpl Wardrik.Workspace, for: WardrikWorkspace.Backend.Store do
  defdelegate read(workspace, tree, path), to: WardrikWorkspace.Backend.Store
  defdelegate write(workspace, tree, path, opts), to: WardrikWorkspace.Backend.Store
  defdelegate delete(workspace, tree, path, opts), to: WardrikWorkspace.Backend.Store
  defdelegate list(workspace, tree, prefix), to: WardrikWorkspace.Backend.Store
  defdelegate paths(workspace, tree, prefix), to: WardrikWorkspace.Backend.Store
end
