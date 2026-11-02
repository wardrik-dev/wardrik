defmodule WardrikWorkspace.Files do
  @moduledoc """
  Stores trees of files in a `WardrikStore`, each file with its own version.

  Every change is made over a version:

    * `nil` - writes only where no file is.
    * a version - writes only if the file is still at that version.

  Otherwise it returns `{:error, :conflict}`. This keeps two writers from losing each other's work.

  Tree names are opaque: tree `shared/acme` doesn't contain tree `shared/acme/runbooks`.
  """

  alias WardrikWorkspace.File

  @typedoc "A file's version, as the model is shown it."
  @type version() :: String.t()

  @doc """
  Returns the file at `:path` in `:tree`, with its version, or `:none`.

      WardrikWorkspace.Files.read(store, tree: "shared/acme/runbooks", path: "deploy.md")
  """
  @spec read(WardrikStore.t(), tree: String.t(), path: String.t()) ::
          {:ok, File.t(), version()} | :none
  def read(store, args) do
    case WardrikStore.lookup(scoped(store), key(args)) do
      {%File{} = file, vsn} -> {:ok, file, version(vsn)}
      nil -> :none
    end
  end

  @doc """
  Writes `:file` at `:path` in `:tree`.

      WardrikWorkspace.Files.write(store,
        tree: "shared/acme/runbooks",
        path: "deploy.md",
        file: %WardrikWorkspace.File{content: "Roll forward."},
        version: nil
      )

  With a `nil` `:version`, writes only where no file is. Otherwise writes only over `:version`.
  Returns `{:error, :conflict}` if that doesn't hold.
  """
  @spec write(WardrikStore.t(),
          tree: String.t(),
          path: String.t(),
          file: File.t(),
          version: version() | nil
        ) :: {:ok, version()} | {:error, :conflict | term()}
  def write(store, args) do
    %File{} = file = Keyword.fetch!(args, :file)

    with {:ok, vsn} <- vsn(Keyword.fetch!(args, :version)),
         {:ok, written} <- WardrikStore.put(scoped(store), key(args), file, if_vsn: vsn),
         do: {:ok, version(written)}
  end

  @doc """
  Deletes the file at `:path` in `:tree`. Returns `{:error, :conflict}` unless it's still at
  `:version`.

      WardrikWorkspace.Files.delete(store,
        tree: "shared/acme/runbooks",
        path: "deploy.md",
        version: version
      )
  """
  @spec delete(WardrikStore.t(), tree: String.t(), path: String.t(), version: version()) ::
          :ok | {:error, :conflict | term()}
  def delete(store, args) do
    with {:ok, vsn} <- vsn(Keyword.fetch!(args, :version)),
         do: WardrikStore.delete(scoped(store), key(args), if_vsn: vsn)
  end

  @doc "Returns every path in `tree`."
  @spec paths(WardrikStore.t(), String.t()) :: [String.t()]
  def paths(store, tree) do
    prefix = tree <> "//"

    for key <- WardrikStore.keys(scoped(store), prefix),
        do: String.replace_prefix(key, prefix, "")
  end

  @doc "Returns every file in `tree`, with its path and version."
  @spec list(WardrikStore.t(), String.t()) :: [{String.t(), File.t(), version()}]
  def list(store, tree) do
    for path <- paths(store, tree),
        {:ok, file, version} <- [read(store, tree: tree, path: path)],
        do: {path, file, version}
  end

  defp scoped(store), do: WardrikStore.scope(store, "wardrik_workspace")
  defp key(args), do: Keyword.fetch!(args, :tree) <> "//" <> Keyword.fetch!(args, :path)

  defp version(vsn), do: vsn |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  defp vsn(nil), do: {:ok, nil}

  defp vsn(version) when is_binary(version) do
    case Base.url_decode64(version, padding: false) do
      {:ok, binary} -> term(binary)
      :error -> {:error, :conflict}
    end
  end

  defp term(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :conflict}
  end
end
