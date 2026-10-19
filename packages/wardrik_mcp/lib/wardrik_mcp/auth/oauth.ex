defmodule WardrikMCP.Auth.OAuth do
  @moduledoc """
  A server its owner signs in to in a browser, as the server's own
  authorization server asks: discovered from the server, registered with
  dynamically, and granted for `:scopes`. The token is kept in the vault
  for the owner under the server's name; see `WardrikMCP.Servers.Providers`.
  """

  defstruct scopes: []

  @type t() :: %__MODULE__{scopes: [String.t()]}

  defimpl WardrikMCP.Auth do
    alias Wardrik.Resource

    def options(_oauth, key), do: [credential: Resource.basename(key)]
    def name(_oauth), do: "oauth"

    def provider(%{scopes: scopes}, key, url),
      do:
        {:ok,
         WardrikOAuth.Provider.new(Resource.basename(key),
           resource: url,
           scopes: scopes,
           flow: :browser,
           trust: :discovered
         )}
  end
end
