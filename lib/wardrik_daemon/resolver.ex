defmodule WardrikDaemon.Resolver do
  @moduledoc """
  Says what each agent gets. It's the daemon's `Wardrik.Resolver`.

    * It acts for its owner (see `WardrikDaemon.Owners`): a person, or its org.
    * It's held to `"*"`'s policy, then its org's, and to the budgets they pool, as
      `WardrikDaemon.Ceiling`s. See `WardrikDaemon.Orgs`.
    * Its tools reach the servers `config.yaml` gives its org, and those added at runtime by its
      owner, its org and the deployment. The nearest of a name wins.
    * Its notices reach targets the same way.

  An agent of an org `config.yaml` doesn't declare, or whose policy `policies/` doesn't hold,
  resolves to nothing: it isn't defined or started.
  """

  @behaviour Wardrik.Resolver

  alias Wardrik.Error
  alias Wardrik.Resolved
  alias Wardrik.Resolver.Request
  alias WardrikCore.Principal
  alias WardrikDaemon.Owners

  @impl Wardrik.Resolver
  def resolve(%Request{agent: id}, %{wardrik: wardrik, config: config} = opts) do
    with {:ok, owner} <- owner(id),
         org = Owners.org(owner),
         {:ok, settings} <- WardrikDaemon.Orgs.settings(org, opts) do
      chain = Owners.chain(owner)
      running = Wardrik.Instance.fetch!(wardrik)

      {:ok,
       %Resolved{
         principal: %Principal{id: owner},
         policy: settings.policy,
         middleware: middleware(opts.store, org, settings.ceilings),
         servers: nearest(added_servers(running, chain) ++ configured_servers(config, org)),
         notify: nearest(added_targets(running, chain) ++ configured_targets(config, org))
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

  defp added_servers(running, chain) do
    for owner <- chain,
        name <- Wardrik.Operations.Owners.added(running, owner),
        do: {name, Wardrik.MCPTools.key(owner, name)}
  end

  defp configured_servers(config, org) do
    for {name, opts} <- config.mcp, for?(opts[:orgs], org), do: {to_string(name), to_string(name)}
  end

  defp added_targets(running, chain) do
    for owner <- chain,
        target <- Wardrik.Notify.owned(running, owner),
        do: {target.name, Wardrik.Notify.key(target)}
  end

  defp configured_targets(config, org) do
    for {name, {_module, opts}} <- Keyword.get(config.notify, :targets, []),
        for?(opts[:orgs], org),
        do: {to_string(name), to_string(name)}
  end

  defp for?(nil, _org), do: true
  defp for?(orgs, org), do: org in orgs

  # Nearest first: the first of each name wins.
  defp nearest(named), do: named |> Enum.reverse() |> Map.new()
end
