defmodule Wardrik.Connections.Owner do
  @moduledoc """
  Whose connections a call to `Wardrik.Connections` is about: the
  prefix of the agents an owner owns, and the owner it is to the host.
  """

  alias Wardrik.AgentID.Prefix

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
