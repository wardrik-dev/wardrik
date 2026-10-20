defmodule MyApp.Issuer do
  @moduledoc """
  The token each signed-in user acts with: reader and messenger on their
  org's agents, and owner of their own; and the app's own, as the
  deployment, reading every agent's events.
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

  @doc "What the app itself reads, as the deployment: every agent's events, and where it stands."
  def deployment do
    [
      %Wardrik.Statement{
        actions: ["agent.events", "agent.read"],
        resources: [Resource.parse!("*/agent/*")]
      }
    ]
  end
end

defimpl Wardrik.Issuer, for: MyApp.Issuer do
  def issue(_issuer, principal, _opts) do
    case String.split(Wardrik.Principal.id(principal), "/") do
      ["deployment"] -> %Wardrik.Token{principal: principal, scope: MyApp.Issuer.deployment()}
      ["slack:" <> _team, _id] -> MyApp.Slack.token(principal)
      [org, "@" <> id] -> %Wardrik.Token{principal: principal, scope: MyApp.Issuer.scope(org, id)}
      _other -> %Wardrik.Token{principal: principal}
    end
  end
end
