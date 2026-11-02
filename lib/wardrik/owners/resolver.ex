defmodule Wardrik.Owners.Resolver do
  @moduledoc """
  Resolves agents along the owner chain, as Wardrik does without `:resolver`. See
  `Wardrik.Resolver`.

  An agent acts for its owner, the part of its ID before its name: `acme/@maria` for
  `acme/@maria/notes`. Its org's settings (`Wardrik.Orgs`) give its policies, defaults and
  ceilings.

  A name its definition uses reaches the nearest server or notify target of that name along
  `Wardrik.Owners.chain/1`: the person's own, their org's, the deployment's, then the one Wardrik
  started with, if that serves the org.
  """

  alias Wardrik.AgentID
  alias Wardrik.Definition
  alias Wardrik.MCPTools
  alias Wardrik.Notify
  alias Wardrik.Orgs
  alias Wardrik.Owners
  alias Wardrik.Resolved

  @doc "Returns what the request's agent gets along its owner's chain."
  @spec resolve(Wardrik.t(), Wardrik.Resolver.Request.t()) ::
          {:ok, Resolved.t()} | {:error, Wardrik.Error.t()}
  def resolve(wardrik, %Wardrik.Resolver.Request{agent: id}) do
    org = Orgs.org(id)

    with {:ok, settings} <- Orgs.settings(wardrik, org) do
      {:ok,
       %Resolved{
         principal: Definition.principal(id),
         policy: settings.policy,
         policies: settings.policies,
         defaults: settings.defaults,
         middleware: Orgs.middleware(wardrik, org, settings),
         servers: servers(wardrik, id, org),
         notify: notify(wardrik, id)
       }}
    end
  end

  defp servers(wardrik, id, org) do
    added =
      for owner <- Owners.chain(Definition.principal(id).id),
          name <- Wardrik.Operations.Owners.added(wardrik, owner),
          do: {name, MCPTools.key(owner, name)}

    started =
      for {name, _opts} <- MCPTools.serving(wardrik, org), do: {to_string(name), to_string(name)}

    nearest(added ++ started)
  end

  defp notify(wardrik, id) do
    {:ok, %AgentID{owner: owner}} = AgentID.parse(id)
    nearest(for target <- Notify.targets(wardrik, owner), do: {target.name, Notify.key(target)})
  end

  # Nearest first: the first of each name wins.
  defp nearest(named), do: named |> Enum.reverse() |> Map.new()
end
