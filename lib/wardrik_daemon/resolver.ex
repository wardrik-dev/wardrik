defmodule WardrikDaemon.Resolver do
  @moduledoc """
  Says what each agent gets. It's the daemon's `Wardrik.Resolver`.

    * It acts for its owner, from its record (see `WardrikDaemon.AgentRecords`): a person, or
      its org. An agent the daemon made no record of resolves to nothing.
    * It's held to `"*"`'s policy, then its org's, and to the budgets they pool, as
      `WardrikDaemon.Ceiling`s. See `WardrikDaemon.Orgs`.
    * Its tools reach the servers its owner, its org and the deployment added, then those
      `config.yaml` gives its org. The nearest of a name wins. See `WardrikDaemon.Servers`.
    * Its notices reach targets the same way. See `WardrikDaemon.NotifyTargets`.
    * Each channel posts its notices in the workspace its owner added the channel to, else its
      org's, else one `config.yaml` gives every org. Never another org's.
    * It mounts the workspaces `config.yaml`'s `workspace.shared` shares with it by its name,
      each of an agent of that name in its own org, with the access given there. See
      `WardrikDaemon.Config`.

  An agent of an org `config.yaml` doesn't declare, or whose policy `policies/` doesn't hold,
  resolves to nothing: it isn't defined or started.
  """

  @behaviour Wardrik.Resolver

  alias Wardrik.Error
  alias Wardrik.Resolved
  alias Wardrik.Resolver.Request
  alias WardrikCore.Principal
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.NotifyTargets
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Servers

  @impl Wardrik.Resolver
  def resolve(%Request{agent: id}, opts) do
    with {:ok, %{owner: owner, org: org} = record} <- record(opts.store, id),
         {:ok, settings} <- WardrikDaemon.Orgs.settings(org, opts) do
      {:ok,
       %Resolved{
         principal: %Principal{id: owner},
         policy: settings.policy,
         middleware: middleware(opts.store, org, settings.ceilings),
         servers: nearest(Servers.reached(opts, owner)),
         notify: nearest(NotifyTargets.reached(opts, owner)),
         channels: channels(opts, owner),
         workspaces: workspaces(opts.store, opts.config.workspace, record)
       }}
    end
  end

  defp record(store, id) do
    case AgentRecords.fetch(store, id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, Error.new(:not_found, "There's no agent #{id} here.")}
    end
  end

  defp middleware(_store, _org, []), do: []

  defp middleware(store, org, ceilings),
    do: [{WardrikDaemon.Ceiling, %{store: store, org: org, ceilings: ceilings}}]

  defp channels(%{wardrik: wardrik, config: config}, owner) do
    for {name, _channel} <- config.channels,
        name = to_string(name),
        workspace = workspace(wardrik, name, owner),
        workspace != nil,
        into: %{},
        do: {name, workspace}
  end

  # The owner's own installation, then its org's, then one config.yaml gives every org.
  defp workspace(wardrik, channel, owner) do
    Enum.find_value(Enum.uniq([owner, Owners.org(owner), "*"]), fn holder ->
      case Wardrik.Channels.owned(wardrik, channel: channel, owner: holder) do
        [installation | _rest] -> installation.workspace
        [] -> nil
      end
    end)
  end

  # Names are the agents' in the mounting agent's own org.
  defp workspaces(store, shared, %{org: org, name: name}) do
    for {sharer, access} <- Keyword.get(shared, :shared, %{}),
        mode = mode(access, name),
        mode != nil,
        {:ok, %{id: tree}} <- [AgentRecords.named(store, org, sharer)],
        into: %{},
        do: {tree, mode}
  end

  defp mode(%{write: write, read: read}, agent) do
    cond do
      agent in write -> :write
      agent in read -> :read
      true -> nil
    end
  end

  # Nearest first: the first of each name wins.
  defp nearest(named), do: named |> Enum.reverse() |> Map.new()
end
