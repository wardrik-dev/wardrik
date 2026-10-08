defmodule WardrikWorkspace.Backend.Store do
  @moduledoc """
  The default `WardrikWorkspace.Backend`: every file a record in `WardrikStore`,
  in the `:files` namespace under its tree and path, so a tree is wherever the
  store is, on every node, on EKV, Postgres or a bucket alike.

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

  @behaviour WardrikWorkspace.Backend

  alias WardrikWorkspace.File

  @ns :files
  @between "//"

  @impl true
  def read(tree, path) do
    with {:ok, key} <- key(tree, path) do
      case WardrikStore.lookup(@ns, key) do
        {%File{} = file, version} -> {:ok, file, version}
        _none -> :none
      end
    end
  end

  @impl true
  def write(tree, path, %File{} = file, version) do
    with {:ok, key} <- key(tree, path), do: WardrikStore.put(@ns, key, file, if_vsn: version)
  end

  @impl true
  def delete(tree, path, version) do
    with {:ok, key} <- key(tree, path), do: WardrikStore.delete(@ns, key, if_vsn: version)
  end

  # Every key under `tree//` is this tree's, whatever `prefix` adds to it, so
  # only the tree needs to be normalised.
  @impl true
  def list(tree, prefix) do
    with :ok <- normalised(tree, :not_a_tree) do
      root = tree <> @between

      files =
        for key <- WardrikStore.keys(@ns, root <> prefix),
            path = String.replace_prefix(key, root, ""),
            {:ok, file, version} <- [read(tree, path)],
            do: {path, file, version}

      {:ok, files}
    end
  end

  @impl true
  def paths(tree, prefix) do
    with :ok <- normalised(tree, :not_a_tree) do
      root = tree <> @between

      {:ok,
       for(
         key <- WardrikStore.keys(@ns, root <> prefix),
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
