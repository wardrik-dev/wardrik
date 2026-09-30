defmodule WardrikWorkspace.Backend.Store do
  @moduledoc """
  The default `WardrikWorkspace.Backend`: every file a record in `Wardrik.Store`,
  in the `:files` namespace under its tree and path, so a tree is wherever the
  store is, on every node, on EKV, Postgres or a bucket alike.

      files / agents/acme/jon/triage/MEMORY.md
      files / shared/acme/findings/2026-09-30-db-failover.md

  A file's version is the store's version of its record, and every change is
  a conditional write on that one key.
  """

  @behaviour WardrikWorkspace.Backend

  alias WardrikWorkspace.File

  @ns :files

  @impl true
  def read(tree, path) do
    case Wardrik.Store.lookup(@ns, key(tree, path)) do
      {%File{} = file, version} -> {:ok, file, version}
      _none -> :none
    end
  end

  @impl true
  def write(tree, path, %File{} = file, version),
    do: Wardrik.Store.put(@ns, key(tree, path), file, if_vsn: version)

  @impl true
  def delete(tree, path, version), do: Wardrik.Store.delete(@ns, key(tree, path), if_vsn: version)

  @impl true
  def list(tree, prefix) do
    root = tree <> "/"

    files =
      for key <- Wardrik.Store.keys(@ns, root <> prefix),
          path = String.replace_prefix(key, root, ""),
          {:ok, file, version} <- [read(tree, path)],
          do: {path, file, version}

    {:ok, files}
  end

  defp key(tree, path), do: tree <> "/" <> path
end
