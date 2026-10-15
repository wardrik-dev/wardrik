defmodule MyApp.Grants do
  @moduledoc """
  What each signed-in user may do with agents: read and message their org's,
  and everything with their own.
  """

  alias Wardrik.AgentID.Prefix

  defstruct []

  @doc "Who `user` is to Wardrik: a user, known by their org and id."
  def principal(%MyApp.Accounts.User{} = user),
    do: Wardrik.Principal.new(:user, "#{user.org}/#{user.id}", name: user.email)

  @doc "The agents `user` owns: `acme/@42/`."
  def own(%MyApp.Accounts.User{} = user), do: Prefix.new!(org: user.org, user: to_string(user.id))

  @doc "What the user `id` of `org` may do."
  def of(org, id) do
    {:ok, org_agents} = Wardrik.Grant.new(Prefix.new!(org: org), [:read, :message])
    {:ok, own_agents} = Wardrik.Grant.new(Prefix.new!(org: org, user: id))
    [org_agents, own_agents]
  end
end

defimpl Wardrik.Grants, for: MyApp.Grants do
  def grants(_grants, principal) do
    case {Wardrik.Principal.type(principal), String.split(Wardrik.Principal.id(principal), "/")} do
      {:user, [org, id]} -> MyApp.Grants.of(org, id)
      _other -> []
    end
  end
end
