defprotocol WardrikChannel.Installations do
  @moduledoc """
  Where a host keeps the workspaces each channel is installed in, as
  `WardrikChannel.Installation`s: a token is a secret, so the host keeps it
  as it keeps its own, such as in a vault.

  An adapter finds the installation of each workspace it hears from with
  `fetch/3`, by the id the medium gives the workspace; `put/2` keeps one
  someone has just installed, and `delete/3` forgets one taken out. A
  notice posted in a room finds the workspace of the agent's own owner
  with `owned/3`.
  `WardrikChannel.Installations.Config` is the installations a
  deployment's config names, one per channel.
  """

  @doc "The installation of `channel` in the workspace the medium knows as `workspace`."
  @spec fetch(t(), String.t(), String.t()) :: {:ok, WardrikChannel.Installation.t()} | :error
  def fetch(installations, channel, workspace)

  @doc """
  Where `channel` was installed for `owner` itself, as each installation's
  `:owner` names it: the workspaces a notice for one of its agents may be
  posted in.
  """
  @spec owned(t(), String.t(), Wardrik.Resource.t()) :: [WardrikChannel.Installation.t()]
  def owned(installations, channel, owner)

  @doc """
  Keeps `installation`, in place of any of the same channel and workspace.
  A new one carries the channel's approvers. Keep your own for the
  workspace instead where your app names them.
  """
  @spec put(t(), WardrikChannel.Installation.t()) :: :ok | {:error, String.t()}
  def put(installations, installation)

  @doc "Forgets the installation of `channel` in `workspace`."
  @spec delete(t(), String.t(), String.t()) :: :ok
  def delete(installations, channel, workspace)
end
