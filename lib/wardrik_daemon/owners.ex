defmodule WardrikDaemon.Owners do
  @moduledoc """
  Reads who owns each agent, and what owners are.

  An owner is the deployment, an org such as `acme`, or a person in one, as `acme/@jon`. An agent's
  owner and org are in its record, never in its ID. See `WardrikDaemon.AgentRecords`.
  """

  alias WardrikDaemon.AgentRecords

  @deployment "deployment"
  @held [:secret, :ceiling, :mcp_server, :notify_target, :provider, :connection, :agents]

  @doc """
  Returns the owner of the agent `id`, from its record in `store`, or `:error` if the daemon made
  no such agent.

      WardrikDaemon.Owners.owner(store, "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN")
      #=> {:ok, "acme/@jon"}
  """
  @spec owner(WardrikStore.t(), String.t()) :: {:ok, String.t()} | :error
  def owner(store, id) do
    with {:ok, record} <- AgentRecords.fetch(store, id), do: {:ok, record.owner}
  end

  @doc """
  Returns whether `owner` is one the daemon names: the deployment, an org, or a person in one.

      WardrikDaemon.Owners.valid?("acme/@jon")
      #=> true

      WardrikDaemon.Owners.valid?("acme/triage")
      #=> false
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
  Returns the org a resource is in, or `nil` if it's in none: the deployment, what the deployment
  owns, tokens, and an agent the daemon made no record of. What an owner holds is in its org: its
  agents, secrets, servers, notify targets, OAuth apps and connections, as are an org's ceilings.

      WardrikDaemon.Owners.org_of(store, {:agent, "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN"})
      #=> "acme"
  """
  @spec org_of(WardrikStore.t(), Wardrik.Authorizer.Request.resource()) :: String.t() | nil
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
  Returns whether `owner` is `within` itself, or a person in the org `within`.

      WardrikDaemon.Owners.within?("acme/@jon", "acme")
      #=> true

      WardrikDaemon.Owners.within?("acme", "acme/@jon")
      #=> false
  """
  @spec within?(String.t(), String.t()) :: boolean()
  def within?(owner, within), do: owner == within or org(owner) == within

  @doc """
  Returns the owners whose settings `owner`'s agents use, nearest first: its own, its org's for a
  person, then the deployment's.

      WardrikDaemon.Owners.chain("acme/@jon")
      #=> ["acme/@jon", "acme", "deployment"]
  """
  @spec chain(String.t()) :: [String.t()]
  def chain(owner) do
    case org(owner) do
      ^owner -> [owner, @deployment]
      org -> [owner, org, @deployment]
    end
  end

  defp segment?(segment),
    do: segment != "" and not String.contains?(segment, ["@", ":", "*", "?"]) and segment != ".."
end
