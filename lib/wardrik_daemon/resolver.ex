defmodule WardrikDaemon.Resolver do
  @moduledoc """
  Says what each agent gets. It's the daemon's `Wardrik.Resolver`.

    * It acts for its owner (see `WardrikDaemon.Owners`): a person, or its org.
    * It's held to `"*"`'s policy, then its org's, and to the budgets they pool, as
      `WardrikDaemon.Ceiling`s. See `WardrikDaemon.Orgs`.
    * Its tools reach the servers its owner, its org and the deployment added, then those
      `config.yaml` gives its org. The nearest of a name wins. See `WardrikDaemon.Servers`.
    * Its notices reach targets the same way. See `WardrikDaemon.NotifyTargets`.

  An agent of an org `config.yaml` doesn't declare, or whose policy `policies/` doesn't hold,
  resolves to nothing: it isn't defined or started.
  """

  @behaviour Wardrik.Resolver

  alias Wardrik.Error
  alias Wardrik.Resolved
  alias Wardrik.Resolver.Request
  alias WardrikCore.Principal
  alias WardrikDaemon.NotifyTargets
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Servers

  @impl Wardrik.Resolver
  def resolve(%Request{agent: id}, opts) do
    with {:ok, owner} <- owner(id),
         org = Owners.org(owner),
         {:ok, settings} <- WardrikDaemon.Orgs.settings(org, opts) do
      {:ok,
       %Resolved{
         principal: %Principal{id: owner},
         policy: settings.policy,
         middleware: middleware(opts.store, org, settings.ceilings),
         servers: nearest(Servers.reached(opts, owner)),
         notify: nearest(NotifyTargets.reached(opts, owner))
       }}
    end
  end

  defp owner(id) do
    case Owners.owner(id) do
      {:ok, owner} -> {:ok, owner}
      :error -> {:error, Error.new(:not_found, "There's no agent #{id} here.")}
    end
  end

  defp middleware(_store, _org, []), do: []

  defp middleware(store, org, ceilings),
    do: [{WardrikDaemon.Ceiling, %{store: store, org: org, ceilings: ceilings}}]

  # Nearest first: the first of each name wins.
  defp nearest(named), do: named |> Enum.reverse() |> Map.new()
end
