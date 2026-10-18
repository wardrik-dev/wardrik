defmodule Wardrik.Connections.Owner do
  @moduledoc """
  Whose connections a call to `Wardrik.Connections` is about: the
  prefix of the agents an owner owns, as a caller's grant names it, and the
  owner it is to the host.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Caller
  alias Wardrik.Error
  alias Wardrik.Principal

  @doc """
  The prefix of the owner `caller` asks about: `:person` for their own,
  within their org, or `:org` for their org's. A caller's org is the one
  its grant reaches, and its person the user its grant is for, else the
  user it acts as, whose agents its grant must reach as well: a grant on
  the tenant, `acme/*`, does, and one on the org's own agents does not.
  """
  @spec owner(Caller.t(), :person | :org) :: {:ok, Prefix.t()} | {:error, Error.t()}
  def owner(%Caller{grant: grant} = caller, whose) do
    case {Prefix.org(grant.scope), whose} do
      {nil, _whose} ->
        {:error,
         Error.new(
           :invalid,
           "This caller reaches every org, and connections belong to one; use a token for an org"
         )}

      {org, :org} ->
        {:ok, Prefix.new!(org: org)}

      {org, :person} ->
        case Prefix.user(grant.scope) || user(caller.principal) do
          nil ->
            {:error,
             Error.new(
               :invalid,
               "This caller acts for no person; ask for the org's connections with owner=org"
             )}

          user ->
            {:ok, Prefix.new!(org: org, user: user)}
        end
    end
  end

  defp user(nil), do: nil
  defp user(principal), do: if(Principal.type(principal) == :user, do: Principal.id(principal))

  @doc "The owner whose agents are under `prefix`."
  @spec owner_of(Prefix.t()) :: Wardrik.Connections.owner()
  def owner_of(prefix) do
    case {Prefix.org(prefix), Prefix.user(prefix)} do
      {org, nil} when is_binary(org) -> org
      {org, user} -> {org, user}
    end
  end

  @doc "The prefix of the agents `owner` owns: `nil`, the deployment's, is every agent."
  @spec prefix(Wardrik.Connections.owner() | nil) :: Prefix.t()
  def prefix(nil), do: Prefix.all()
  def prefix({org, user}), do: Prefix.new!(org: org, user: user)
  def prefix(org) when is_binary(org), do: Prefix.new!(org: org)
end
