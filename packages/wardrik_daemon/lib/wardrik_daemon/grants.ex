defmodule WardrikDaemon.Grants do
  @moduledoc """
  What each person or system that reaches the daemon may do, as
  `Wardrik.Grants` asks, by how they reached it:

    * `:shell`, `:terminal` and `:ssh` - everything, on every agent: they
      hold the node itself
    * `:token` - what the HTTP API token it names grants, until the token
      is revoked
    * `:channel` - what `config.yaml`'s `channels` says of someone in that
      channel, as it names people, in each org whose agents it offers; see
      below
    * anyone else - nothing

  In a channel, someone its `admins` name may read, message and decide on
  the agents, and define them where `defaults` names a policy of
  `policies/`, which holds what they define as a ceiling. Someone its
  `approvers` name, or the `approvers` of a `notify` target that posts in
  it, may read, message and decide; with `approvers: anyone`, everyone in
  it may. Anyone else may read and message, and decides only what they
  asked for: whoever asked for a turn may decide what it waits on in any
  case (see `Wardrik.Agent.decide/3`), and a turn nobody asked for, such as
  a trigger's, is decided by those the channel names, or from a shell.

      channels:
        slack:
          type: slack
          admins: ["@jon"]
          approvers: ["@maria", "ana@example.com"]   # or: anyone

  A grant reaches the agents of the channel's orgs, and none of their
  users': see `Wardrik.AgentID.Prefix`.
  """

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Grant
  alias Wardrik.Principal
  alias WardrikDaemon.Agents
  alias WardrikDaemon.Config

  @enforce_keys [:store, :agents]
  defstruct [:store, :agents]

  @typedoc """
  The daemon's `Wardrik.Grants`: tokens' grants read from `:store`, and the
  channels' people from the config of `:agents`, the daemon's definitions.
  """
  @type t() :: %__MODULE__{store: WardrikStore.t(), agents: Agents.t()}

  @everyone [:read, :message]
  @deciders [:read, :message, :decide]

  @doc false
  def grants(%__MODULE__{} = grants, principal),
    do: granted(Principal.type(principal), principal, grants)

  defp granted(type, _principal, _grants) when type in [:shell, :terminal, :ssh] do
    {:ok, root} = Grant.new(Prefix.all())
    [root]
  end

  defp granted(:token, principal, %__MODULE__{store: store}) do
    case WardrikHTTP.Token.get(store, Principal.id(principal)) do
      {:ok, token} -> [token.grant]
      :error -> []
    end
  end

  defp granted(:channel, principal, %__MODULE__{agents: agents}) do
    {channel, _workspace, user} = WardrikChannel.person(principal)

    case Agents.installation(agents, channel) do
      {:ok, installation} -> member(agents, WardrikChannel.Member.new(installation, user))
      :error -> []
    end
  end

  defp granted(_type, _principal, _grants), do: []

  # Someone in the workspace of a channel's installation, by their id there.
  defp member(agents, %WardrikChannel.Member{installation: installation} = member) do
    channel = installation.channel

    {can, ceiling} =
      cond do
        include?(agents, Agents.admins(agents, channel), member) -> admin(agents)
        decides?(agents, member) -> {@deciders, []}
        true -> {@everyone, []}
      end

    for scope <- scopes(agents, channel) do
      {:ok, grant} = Grant.new(scope, can, ceiling)
      grant
    end
  end

  # An admin defines only under a policy the deployment names for it.
  defp admin(agents) do
    with %{"policy" => name} when is_binary(name) <- Agents.defaults(agents),
         {:ok, ceiling} <- Agents.ceiling(agents, name) do
      {@deciders ++ [:define], ceiling}
    else
      _none -> {@deciders, []}
    end
  end

  defp decides?(agents, %WardrikChannel.Member{installation: installation} = member) do
    include? = &include?(agents, &1, member)

    WardrikChannel.Approvers.decides?(Agents.approvers(agents, installation), include?) or
      include?.(notifying(agents, installation.channel))
  end

  # As the channel's adapter knows people, from the channel's settings; never
  # in a channel config.yaml does not name.
  defp include?(agents, names, %WardrikChannel.Member{installation: installation} = member) do
    case Enum.find(channels(agents), fn {name, _configured} ->
           Atom.to_string(name) == installation.channel
         end) do
      {_name, configured} -> WardrikChannel.include?(configured, names, member)
      nil -> false
    end
  end

  defp channels(agents),
    do: agents.config |> Config.section(WardrikChannel) |> Keyword.get(:channels, [])

  # The approvers of the notify targets posting in the channel.
  defp notifying(agents, channel) do
    targets = agents.config |> Config.section(WardrikNotify) |> Keyword.get(:targets, [])

    for {name, posting} <- channels(agents),
        Atom.to_string(name) == channel,
        {_target, {_module, options}} <- targets,
        Keyword.get(options, :channel) == posting,
        approver <- Keyword.get(options, :approvers, []),
        do: approver
  end

  defp scopes(agents, channel) do
    case Agents.orgs(agents, channel) do
      :all -> [Prefix.all()]
      orgs -> Enum.map(orgs, &Prefix.new!(org: &1))
    end
  end
end

defimpl Wardrik.Grants, for: WardrikDaemon.Grants do
  defdelegate grants(grants, principal), to: WardrikDaemon.Grants
end
