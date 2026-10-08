defmodule WardrikWorkspace.Backend do
  @moduledoc """
  Where a workspace's trees are kept. A tree is a set of files under paths, as
  `WardrikWorkspace.Path` writes them, and a backend keeps each file as a
  `WardrikWorkspace.File` with a version of its own.

  `WardrikWorkspace.Backend.Store` keeps them in `WardrikStore`, the default.
  A backend over something a team already runs, a repository or a bucket of
  its own, implements this behaviour and passes
  `WardrikWorkspace.Backend.Conformance`.

  Every change a file tool makes is conditional on the version it read: a
  write where nothing is written, or over the version read, answering
  `{:error, :conflict}` where the file has changed since. That is the one
  guarantee a backend gives, and what keeps two writers from losing each
  other's changes. The decisions about a call, its policy, its gate and its
  labels, are made before a backend is asked anything.

  A tree is named by a string the backend treats as opaque:
  `agents/<org>/<user>/<name>` for an agent's own, and `shared/<name>` for a
  tree agents share. Opaque means one tree never holds another's files, even
  where its name begins the other's: `shared/acme` and `shared/acme/runbooks`
  are two trees, and `runbooks/x.md` in the first is not `x.md` in the second.
  Each may be shared with different agents, or only to read.
  """

  alias WardrikWorkspace.File

  @typedoc "A tree, as `WardrikWorkspace.Mount` names it."
  @type tree() :: String.t()

  @typedoc "What a backend stamps a file with. Opaque."
  @type version() :: term()

  @doc "The file at `path` in `tree`, with its version, or `:none` where there is none."
  @callback read(tree(), path :: String.t()) ::
              {:ok, File.t(), version()} | :none | {:error, term()}

  @doc """
  Writes `file` at `path` in `tree`: only where nothing is written for a
  `nil` version, or only over `version`.
  """
  @callback write(tree(), path :: String.t(), File.t(), version() | nil) ::
              {:ok, version()} | {:error, :conflict | term()}

  @doc "Deletes the file at `path` in `tree`, only where its version is `version`."
  @callback delete(tree(), path :: String.t(), version()) :: :ok | {:error, :conflict | term()}

  @doc "Every file in `tree` whose path starts with `prefix`, with its version."
  @callback list(tree(), prefix :: String.t()) ::
              {:ok, [{String.t(), File.t(), version()}]} | {:error, term()}

  @doc """
  The path of every file in `tree` that starts with `prefix`, read without
  the files, for what needs their names alone.
  """
  @callback paths(tree(), prefix :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
end
