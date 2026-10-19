defmodule WardrikDaemon.Issuer do
  @moduledoc """
  The token each person or system that reaches the daemon acts with, as
  `Wardrik.Issuer` asks, by how they reached it:

    * `:shell`, `:terminal` and `:ssh` - `owner` on every agent: they hold
      the node itself
    * `:channel` - what `config.yaml`'s `channels` says of someone in that
      channel, as it names people, on the agents of each org it serves; see
      below
    * `:agent` - `reader` and `messenger` on its owner's agents,
      `acme/agent/*` or `acme/@jon/agent/*`, read from the resource the
      principal is named by, so a turn one agent asks of another reads and
      messages for it what it could itself
    * anyone else - nothing

  Each lasts as long as `config.yaml`'s `tokens.expires.session` says; one
  held past that is refreshed here as it is used, so a change to `channels`
  that takes something away reaches whoever holds one. A token of the HTTP
  API is not issued here: `WardrikHTTP.Tokens` reads it where it is kept.

  In a channel, everyone holds `reader` and `messenger` on the agents of
  the channel's orgs, `acme/agent/*`, and none of their users'; see
  `Wardrik.Resource`. Someone its `approvers` name, or the
  `approvers` of a `notify` target that posts in it, holds `approver` too;
  with `approvers: anyone`, everyone in it does. Someone its `admins` name
  holds `approver`, and `definer` where `defaults` names a policy, which
  the token names as its policy, holding every agent they
  define. Whoever asked for a turn may decide what it waits on in any case
  (see `Wardrik.Agent.decide/3`), and a turn nobody asked for, such as a
  trigger's, is decided by those the channel names, or from a shell.

      channels:
        slack:
          type: slack
          admins: ["@jon"]
          approvers: ["@maria", "ana@example.com"]   # or: anyone
  """

  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Role
  alias Wardrik.Token
  alias WardrikDaemon.Agents
  alias WardrikDaemon.Config

  @enforce_keys [:agents]
  defstruct [:agents]

  @typedoc "The daemon's `Wardrik.Issuer`, reading the channels' people from the config of `:agents`."
  @type t() :: %__MODULE__{agents: Agents.t()}

  @everyone [:reader, :messenger]
  @deciders [:reader, :messenger, :approver]

  @doc false
  def issue(%__MODULE__{agents: agents}, principal, _opts),
    do: issued(Principal.type(principal), principal, agents)

  defp issued(type, principal, _agents) when type in [:shell, :terminal, :ssh],
    do: Token.root(principal)

  defp issued(:agent, principal, _agents) do
    owner = Resource.owner(Resource.parse!(Principal.id(principal)))
    %Token{principal: principal, scope: [Role.bind(@everyone, [agents_of(owner)])]}
  end

  defp issued(:channel, principal, agents) do
    {channel, _workspace, user} = WardrikChannel.person(principal)

    case Agents.installation(agents, channel) do
      {:ok, installation} ->
        member(agents, principal, WardrikChannel.Member.new(installation, user))

      :error ->
        %Token{principal: principal}
    end
  end

  defp issued(_type, principal, _agents), do: %Token{principal: principal}

  # Someone in the workspace of a channel's installation, by their id there.
  defp member(agents, principal, %WardrikChannel.Member{installation: installation} = member) do
    channel = installation.channel

    {roles, policy} =
      cond do
        include?(agents, Agents.admins(agents, channel), member) -> admin(agents)
        decides?(agents, member) -> {@deciders, :none}
        true -> {@everyone, :none}
      end

    %Token{
      principal: principal,
      scope: [Role.bind(roles, reached(agents, channel))],
      policy: policy
    }
  end

  # An admin defines only under a policy the deployment names for it.
  defp admin(agents) do
    case Agents.defaults(agents) do
      %{"policy" => name} when is_binary(name) -> {@deciders ++ [:definer], name}
      _none -> {@deciders, :none}
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

  defp reached(agents, channel) do
    case Agents.orgs(agents, channel) do
      :all -> [agents_of("*")]
      orgs -> Enum.map(orgs, &agents_of/1)
    end
  end

  defp agents_of(owner), do: Resource.parse!("#{owner}/agent/*")
end

defimpl Wardrik.Issuer, for: WardrikDaemon.Issuer do
  defdelegate issue(issuer, principal, opts), to: WardrikDaemon.Issuer
end
