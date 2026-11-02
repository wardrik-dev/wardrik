defmodule WardrikDaemon.Resolver do
  @moduledoc """
  Says what each agent gets. It's the daemon's `Wardrik.Resolver`.

    * It acts for its owner (see `WardrikDaemon.Owners`): a person, or its org.
    * It's held to `"*"`'s policy, then its org's, and to the budgets they pool, as
      `WardrikDaemon.Ceiling`s. See `WardrikDaemon.Orgs`.
    * Its tools reach the servers its owner, its org and the deployment added, then those
      `config.yaml` gives its org. The nearest of a name wins. See `WardrikDaemon.Servers`.
    * Its notices reach targets the same way. See `WardrikDaemon.NotifyTargets`.
    * Each channel posts its notices in the workspace its owner added the channel to, else its
      org's, else one `config.yaml` gives every org. Never another org's.
    * It mounts the workspaces `config.yaml`'s `workspace.shared` shares with it by its ID, with
      the access given there. See `WardrikDaemon.Config`.

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
         notify: nearest(NotifyTargets.reached(opts, owner)),
         channels: channels(opts, owner),
         workspaces: workspaces(opts.config.workspace, Wardrik.AgentID.agent(id))
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

  defp workspaces(shared, agent) do
    for {tree, access} <- Keyword.get(shared, :shared, %{}),
        mode = mode(access, agent),
        mode != nil,
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
