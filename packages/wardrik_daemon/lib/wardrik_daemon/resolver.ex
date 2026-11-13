defmodule WardrikDaemon.Resolver do
  @moduledoc """
  Says what each agent gets. It's the daemon's `Wardrik.Resolver`.

    * The agent acts for its owner, from its record. An agent with no record gets nothing.
    * It's held to `"*"`'s policy and its org's, and their shared budgets. See `WardrikDaemon.Orgs`.
    * It reaches its owner's MCP server of each name, else the one its owner may use as
      `WardrikDaemon.Authorizer` allows, else the deployment's that serves its org. It reaches
      the nearest notify target of each name. See `WardrikDaemon.NotifyTargets`.
    * A channel posts its notices in the workspace its owner added it to, else its org's.
    * It mounts the workspaces `workspace.shared` gives it.
    * An agent of an undeclared org, or whose policy is missing, isn't started.
  """

  @behaviour Wardrik.Resolver

  alias Wardrik.Error
  alias Wardrik.Resolved
  alias Wardrik.Resolver.Request
  alias WardrikCore.Principal
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.NotifyTargets
  alias WardrikDaemon.Owners

  @impl Wardrik.Resolver
  def resolve(%Request{agent: id}, opts) do
    with {:ok, %{owner: owner, org: org} = record} <- record(opts.store, id),
         {:ok, settings} <- WardrikDaemon.Orgs.settings(org, opts) do
      {:ok,
       %Resolved{
         principal: %Principal{id: owner},
         policy: settings.policy,
         middleware: middleware(opts.store, org, settings.ceilings),
         servers: servers(opts, owner, org),
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

  # A server config.yaml starts reaches the orgs it serves alone. Where Wardrik isn't running, as
  # for the doctor, only those are.
  defp servers(%{wardrik: wardrik, config: config}, owner, org) do
    reached =
      case Wardrik.Instance.fetch(wardrik) do
        {:ok, running} -> Wardrik.Operations.Servers.reached(running, %Principal{id: owner})
        :error -> Map.new(config.mcp, fn {name, _opts} -> {to_string(name), to_string(name)} end)
      end

    Map.filter(reached, fn {name, key} ->
      key != name or WardrikDaemon.Config.Orgs.serves?(config, kind: :mcp, name: name, org: org)
    end)
  end

  # Nearest first: the first of each name wins.
  defp nearest(named), do: named |> Enum.reverse() |> Map.new()
end
