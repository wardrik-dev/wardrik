defmodule MyApp.Issuer do
  @moduledoc """
  The token each signed-in user acts with: reader and messenger on their
  org's agents, and owner of their own.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Role

  defstruct []

  @doc "Who `user` is to Wardrik: a user, known by their org and id."
  def principal(%MyApp.Accounts.User{} = user),
    do: Wardrik.Principal.new(:user, "#{user.org}/#{user.id}", name: user.email)

  @doc "The agents `user` owns: `acme/@42/`."
  def own(%MyApp.Accounts.User{} = user), do: Prefix.new!(org: user.org, user: to_string(user.id))

  @doc "What the user `id` of `org` may do."
  def scope(org, id) do
    [
      Role.bind([:reader, :messenger], Prefix.new!(org: org)),
      Role.bind([:owner], Prefix.new!(org: org, user: id))
    ]
  end
end

defimpl Wardrik.Issuer, for: MyApp.Issuer do
  def issue(_issuer, principal, _opts) do
    case {Wardrik.Principal.type(principal), String.split(Wardrik.Principal.id(principal), "/")} do
      {:user, [org, id]} -> %Wardrik.Token{principal: principal, scope: MyApp.Issuer.scope(org, id)}
      _other -> %Wardrik.Token{principal: principal}
    end
  end
end
