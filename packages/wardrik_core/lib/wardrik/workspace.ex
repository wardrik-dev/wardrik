defprotocol Wardrik.Workspace do
  @moduledoc """
  Where agents' files are kept: each tree a set of files under paths, each
  file with a version of its own, as `WardrikWorkspace`'s file tools read
  and write them.

  A host names the value once, as the `:workspace` of its `Wardrik.Host`,
  and every agent's file tools ask it. The value carries what its
  implementation needs, such as the store it keeps files in:

      Wardrik.Host.new(store: store, workspace: %WardrikWorkspace.Backend.Store{store: store})

  A host that keeps none has `Wardrik.Workspace.None`, which answers
  `{:error, :unsupported}`.

  Every change is conditional on the version read: a write where nothing is
  written, or over the version read, answering `{:error, :conflict}` where
  the file has changed since. That is the one guarantee an implementation
  gives, and what keeps two writers from losing each other's changes.

  A tree is named by a string the implementation treats as opaque:
  `agents/<org>/<user>/<name>` for an agent's own, and `shared/<name>` for a
  tree agents share. Opaque means one tree never holds another's files, even
  where its name begins the other's: `shared/acme` and `shared/acme/runbooks`
  are two trees.
  """

  @typedoc "A tree's name."
  @type tree() :: String.t()

  @typedoc "What an implementation stamps a file with. Opaque."
  @type version() :: term()

  @doc "The file at `path` in `tree`, with its version, or `:none` where there is none."
  @spec read(t(), tree(), String.t()) :: {:ok, term(), version()} | :none | {:error, term()}
  def read(workspace, tree, path)

  @doc """
  Writes the `:file` `opts` name at `path` in `tree`: only where nothing is
  written for a `nil` `:version`, or only over it.
  """
  @spec write(t(), tree(), String.t(), file: term(), version: version() | nil) ::
          {:ok, version()} | {:error, :conflict | term()}
  def write(workspace, tree, path, opts)

  @doc "Deletes the file at `path` in `tree`, only where its version is `:version`."
  @spec delete(t(), tree(), String.t(), version: version()) :: :ok | {:error, :conflict | term()}
  def delete(workspace, tree, path, opts)

  @doc "Every file in `tree` whose path starts with `prefix`, with its version."
  @spec list(t(), tree(), String.t()) ::
          {:ok, [{String.t(), term(), version()}]} | {:error, term()}
  def list(workspace, tree, prefix)

  @doc """
  The path of every file in `tree` that starts with `prefix`, read without
  the files, for what needs their names alone.
  """
  @spec paths(t(), tree(), String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def paths(workspace, tree, prefix)
end
