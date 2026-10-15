defmodule WardrikMCP.Servers.Providers do
  @moduledoc """
  Lets an owner sign in to a server they added as `WardrikOAuth` signs in to
  a configured account: each server signed in to is looked up by its name,
  for its owner alone, at its URL, held to the trust of a URL a server named
  rather than one the deployment did.

      oauth = WardrikOAuth.new(added: %WardrikMCP.Servers.Providers{store: store})

  The token is kept in the vault for the owner under the server's name, so
  the server resolves it as its credential, and a call parks on the sign-in
  where the owner has none.
  """

  alias Wardrik.AgentID.Prefix

  @enforce_keys [:store]
  defstruct [:store]

  @type t() :: %__MODULE__{store: WardrikStore.t()}

  @doc "The prefix of the agents a vault owner owns: an org's own, or a person's."
  @spec prefix(WardrikVault.owner()) :: Prefix.t()
  def prefix({org, user}), do: Prefix.new!(org: org, user: user)
  def prefix(org), do: Prefix.new!(org: org)

  defimpl WardrikOAuth.Providers do
    alias Wardrik.Servers.Key
    alias WardrikMCP.Remote
    alias WardrikMCP.Servers.Providers

    def fetch(%{store: store}, name, owner: owner) do
      with {:ok, remote} <- Remote.fetch(store, Key.new(Providers.prefix(owner), name)),
           {:ok, provider} <- Remote.provider(remote) do
        {:ok, provider}
      else
        _absent_or_none -> :error
      end
    end

    def names(%{store: store}) do
      for remote <- Remote.all(store),
          match?({:ok, _provider}, Remote.provider(remote)),
          do: remote.key.name
    end
  end
end
