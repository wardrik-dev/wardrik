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

  @enforce_keys [:store]
  defstruct [:store]

  @type t() :: %__MODULE__{store: WardrikStore.t()}

  defimpl WardrikOAuth.Providers do
    alias Wardrik.Resource
    alias WardrikMCP.Remote

    def fetch(%{store: store}, name, owner: owner) do
      with {:ok, remote} <- Remote.fetch(store, Resource.new(owner, server: name)),
           {:ok, provider} <- Remote.provider(remote) do
        {:ok, provider}
      else
        _absent_or_none -> :error
      end
    end

    def names(%{store: store}) do
      for remote <- Remote.all(store),
          match?({:ok, _provider}, Remote.provider(remote)),
          do: Resource.basename(remote.key)
    end
  end
end
