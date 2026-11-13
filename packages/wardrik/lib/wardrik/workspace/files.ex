defmodule Wardrik.Workspace.Files do
  @moduledoc """
  Stores trees of files in a `Wardrik.Store`, each file with its own version.

      {:ok, version} =
        Wardrik.Workspace.Files.write(store,
          tree: "agents/agt_triage",
          path: "notes.md",
          file: %Wardrik.Workspace.File{content: "Hi"},
          version: nil
        )

    * `version: nil` writes only where no file is. A version writes only over that version.
      Otherwise you get `{:error, :conflict}`.
    * Tree names are opaque: `shared/acme` doesn't contain `shared/acme/runbooks`.
  """

  alias Wardrik.Workspace.File

  @typedoc "A file's version, as the model is shown it."
  @type version() :: String.t()

  @doc """
  Returns the file at `:path` in `:tree`, with its version, or `:none`.

      Wardrik.Workspace.Files.read(store, tree: "agents/agt_triage", path: "notes.md")
  """
  @spec read(Wardrik.Store.t(), tree: String.t(), path: String.t()) ::
          {:ok, File.t(), version()} | :none
  def read(store, args) do
    scoped = scoped(store)

    case Wardrik.Store.lookup(scoped, key(args)) do
      {%File{} = file, vsn} -> {:ok, file, version(vsn)}
      nil -> :none
    end
  end

  @doc "Writes `:file` at `:path` in `:tree`, over `:version`, or returns `{:error, :conflict}`."
  @spec write(Wardrik.Store.t(),
          tree: String.t(),
          path: String.t(),
          file: File.t(),
          version: version() | nil
        ) :: {:ok, version()} | {:error, :conflict | term()}
  def write(store, args) do
    %File{} = file = Keyword.fetch!(args, :file)

    with {:ok, vsn} <- vsn(Keyword.fetch!(args, :version)),
         scoped = scoped(store),
         {:ok, written} <- Wardrik.Store.put(scoped, key(args), file, if_vsn: vsn),
         do: {:ok, version(written)}
  end

  @doc """
  Deletes the file at `:path` in `:tree`. Returns `{:error, :conflict}` unless it's still at
  `:version`.
  """
  @spec delete(Wardrik.Store.t(), tree: String.t(), path: String.t(), version: version()) ::
          :ok | {:error, :conflict | term()}
  def delete(store, args) do
    with {:ok, vsn} <- vsn(Keyword.fetch!(args, :version)) do
      store
      |> scoped()
      |> Wardrik.Store.delete(key(args), if_vsn: vsn)
    end
  end

  @doc "Returns every path in `tree`."
  @spec paths(Wardrik.Store.t(), String.t()) :: [String.t()]
  def paths(store, tree) do
    prefix = tree <> "//"

    scoped = scoped(store)

    for key <- Wardrik.Store.keys(scoped, prefix),
        do: String.replace_prefix(key, prefix, "")
  end

  @doc "Returns every file in `tree`, with its path and version."
  @spec list(Wardrik.Store.t(), String.t()) :: [{String.t(), File.t(), version()}]
  def list(store, tree) do
    for path <- paths(store, tree),
        {:ok, file, version} <- [read(store, tree: tree, path: path)],
        do: {path, file, version}
  end

  defp scoped(store),
    do: Wardrik.Store.scope(store, "wardrik_workspace", format: File)

  defp key(args), do: Keyword.fetch!(args, :tree) <> "//" <> Keyword.fetch!(args, :path)

  defp version(vsn) do
    vsn
    |> :erlang.term_to_binary()
    |> Base.url_encode64(padding: false)
  end

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
