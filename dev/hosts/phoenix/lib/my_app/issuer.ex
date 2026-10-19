defmodule MyApp.Issuer do
  @moduledoc """
  The token each signed-in user acts with: reader and messenger on their
  org's agents, and owner of their own.
  """

  alias Wardrik.Resource
  alias Wardrik.Role

  defstruct []

  @doc "Who `user` is to Wardrik: a person in their org, as `acme/@42`."
  def principal(%MyApp.Accounts.User{} = user),
    do: Wardrik.Principal.new("#{user.org}/@#{user.id}", name: user.email)

  @doc "Who `user` is as an owner of accounts and agents: `acme/@42`."
  def own(%MyApp.Accounts.User{} = user), do: Resource.parse!("#{user.org}/@#{user.id}")

  @doc "What the user `id` of `org` may do."
  def scope(org, id) do
    [
      Role.bind([:reader, :messenger], [Resource.parse!("#{org}/agent/*")]),
      Role.bind([:owner], [Resource.parse!("#{org}/@#{id}/*")])
    ]
  end
end

defimpl Wardrik.Issuer, for: MyApp.Issuer do
  def issue(_issuer, principal, _opts) do
    case String.split(Wardrik.Principal.id(principal), "/") do
      [org, "@" <> id] -> %Wardrik.Token{principal: principal, scope: MyApp.Issuer.scope(org, id)}
      _other -> %Wardrik.Token{principal: principal}
    end
  end
end
