defmodule WardrikDaemon.Owners do
  @moduledoc """
  Who owns each agent, and what an owner is.

  An owner is `deployment`, an org such as `acme`, or a person in one, as `acme/@jon`.
  A user's ID is the person's owner, so `acme/@jon` is the user `user:acme/@jon`.
  An agent's owner is in its record, never its ID. See `WardrikDaemon.AgentRecords`.
  """

  alias WardrikDaemon.AgentRecords

  @deployment "deployment"
  @held [:secret, :ceiling, :mcp_server, :notify_target, :provider, :connection, :agents]

  @doc """
  Returns the owner of agent `id`, or `:error` if the daemon didn't make it.

      WardrikDaemon.Owners.owner(store, "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN")
      #=> {:ok, "acme/@jon"}
  """
  @spec owner(Wardrik.Store.t(), String.t()) :: {:ok, String.t()} | :error
  def owner(store, id) do
    with {:ok, record} <- AgentRecords.fetch(store, id), do: {:ok, record.owner}
  end

  @doc """
  Returns whether `owner` is the deployment, an org, or a person in one.

      WardrikDaemon.Owners.valid?("acme/@jon")
      #=> true
  """
  @spec valid?(String.t()) :: boolean()
  def valid?(@deployment), do: true

  def valid?(owner) do
    case String.split(owner, "/") do
      [org] -> segment?(org)
      [org, "@" <> person] -> segment?(org) and segment?(person)
      _other -> false
    end
  end

  @doc """
  Returns whether `id` is a user's: a person in an org. A user's ID is its owner.

      WardrikDaemon.Owners.user?("acme/@ana")
      #=> true
  """
  @spec user?(String.t()) :: boolean()
  def user?(id), do: valid?(id) and person(id) != nil

  @doc """
  Returns `owner`'s org.

      WardrikDaemon.Owners.org("acme/@jon")
      #=> "acme"
  """
  @spec org(String.t()) :: String.t()
  def org(owner), do: owner |> String.split("/", parts: 2) |> hd()

  @doc """
  Returns the owner that is `person` in `org`.

      WardrikDaemon.Owners.person("acme", "jon")
      #=> "acme/@jon"
  """
  @spec person(String.t(), String.t()) :: String.t()
  def person(org, person), do: org <> "/@" <> person

  @doc """
  Returns the person `owner` is, or `nil` for an org or the deployment.

      WardrikDaemon.Owners.person("acme/@jon")
      #=> "jon"
  """
  @spec person(String.t()) :: String.t() | nil
  def person(owner) do
    case String.split(owner, "/@", parts: 2) do
      [_org, person] -> person
      [_org] -> nil
    end
  end

  @doc """
  Returns the org a resource is in, or `nil` for the deployment's things, tokens and unknown agents.

      WardrikDaemon.Owners.org_of(store, {:agent, "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN"})
      #=> "acme"
  """
  @spec org_of(Wardrik.Store.t(), Wardrik.Authorizer.Request.resource()) :: String.t() | nil
  def org_of(store, {:agent, id}) do
    case AgentRecords.fetch(store, id) do
      {:ok, record} -> record.org
      :error -> nil
    end
  end

  def org_of(_store, {kind, @deployment}) when kind in @held, do: nil
  def org_of(_store, {kind, owner}) when kind in @held, do: org(owner)
  def org_of(_store, {:deployment, _name}), do: nil
  def org_of(_store, {:token, _id}), do: nil

  @doc """
  Returns whether `owner` is `within`, or a person in the org `within`.

      WardrikDaemon.Owners.within?("acme/@jon", "acme")
      #=> true
  """
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(owner, within), do: owner == within or org(owner) == within

  defp segment?(segment),
    do: segment != "" and not String.contains?(segment, ["@", ":", "*", "?"]) and segment != ".."
end
