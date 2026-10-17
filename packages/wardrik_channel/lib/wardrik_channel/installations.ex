defprotocol WardrikChannel.Installations do
  @moduledoc """
  Where a host keeps the workspaces each channel is installed in, as
  `WardrikChannel.Installation`s: a token is a secret, so the host keeps it
  as it keeps its own, such as in a vault.

  An adapter finds the installation of each workspace it hears from with
  `fetch/3`, by the id the medium gives the workspace; `put/2` keeps one
  someone has just installed, and `delete/3` forgets one taken out.
  `WardrikChannel.Installations.Config` is the installations a
  deployment's config names, one per channel.
  """

  @doc "The installation of `channel` in the workspace the medium knows as `workspace`."
  @spec fetch(t(), String.t(), String.t()) :: {:ok, WardrikChannel.Installation.t()} | :error
  def fetch(installations, channel, workspace)

  @doc "Keeps `installation`, in place of any of the same channel and workspace."
  @spec put(t(), WardrikChannel.Installation.t()) :: :ok | {:error, String.t()}
  def put(installations, installation)

  @doc "Forgets the installation of `channel` in `workspace`."
  @spec delete(t(), String.t(), String.t()) :: :ok
  def delete(installations, channel, workspace)
end
