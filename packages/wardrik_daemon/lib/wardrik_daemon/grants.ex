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
  it, may read, message and decide. Anyone else may read and message, and
  decide too where neither names anybody. Whoever asked for a turn may
  decide what it waits on in any case; see `Wardrik.Agent.decide/3`.

      channels:
        slack:
          type: slack
          admins: ["@jon"]
          approvers: ["@maria", "ana@example.com"]
  """

  @behaviour Wardrik.Grants

  alias Wardrik.AgentID.Prefix
  alias Wardrik.Grant
  alias Wardrik.Principal
  alias WardrikDaemon.Agents
  alias WardrikDaemon.Config

  @everyone [:read, :message]
  @deciders [:read, :message, :decide]

  @impl Wardrik.Grants
  def grants(principal), do: granted(Principal.type(principal), principal)

  defp granted(type, _principal) when type in [:shell, :terminal, :ssh] do
    {:ok, root} = Grant.new(Prefix.all())
    [root]
  end

  defp granted(:token, principal) do
    case WardrikHTTP.Token.get(Principal.id(principal)) do
      {:ok, token} -> [token.grant]
      :error -> []
    end
  end

  defp granted(:channel, principal) do
    {channel, user} = WardrikChannel.person(principal)

    {can, ceiling} =
      cond do
        WardrikChannel.among?(channel, user, Agents.admins(channel)) -> admin()
        decides?(channel, user) -> {@deciders, []}
        true -> {@everyone, []}
      end

    for scope <- scopes(channel) do
      {:ok, grant} = Grant.new(scope, can, ceiling)
      grant
    end
  end

  defp granted(_type, _principal), do: []

  # An admin defines only under a policy the deployment names for it.
  defp admin do
    with %{"policy" => name} when is_binary(name) <- Agents.defaults(),
         {:ok, ceiling} <- Agents.ceiling(name) do
      {@deciders ++ [:define], ceiling}
    else
      _none -> {@deciders, []}
    end
  end

  defp decides?(channel, user) do
    case deciders(channel) do
      [] -> true
      named -> WardrikChannel.among?(channel, user, named)
    end
  end

  # The channel's approvers, and those of the notify targets posting in it.
  defp deciders(channel) do
    channels = Keyword.get(Config.settings(WardrikChannel), :channels, [])
    targets = Keyword.get(Config.settings(WardrikNotify), :targets, [])

    Agents.approvers(channel) ++
      for {name, posting} <- channels,
          Atom.to_string(name) == channel,
          {_target, {_module, options}} <- targets,
          Keyword.get(options, :channel) == posting,
          approver <- Keyword.get(options, :approvers, []),
          do: approver
  end

  defp scopes(channel) do
    case Agents.orgs(channel) do
      :all -> [Prefix.all()]
      orgs -> Enum.map(orgs, &Prefix.new!(org: &1))
    end
  end
end
