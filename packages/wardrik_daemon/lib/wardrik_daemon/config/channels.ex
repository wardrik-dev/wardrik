defmodule WardrikDaemon.Config.Channels do
  @moduledoc """
  Reads `config.yaml`'s `channels`: the chat apps agents are reached through.

      channels:
        slack:
          type: slack
          token: ${SLACK_BOT_TOKEN}
          app_token: ${SLACK_APP_TOKEN}
          domains: {acme.com: acme}

    * The name is lower-case letters, digits and `-`. `shell`, `ssh`, `terminal` and `oauth` are taken.
    * `type` is required. `slack` is the only type.
    * It takes `Wardrik.Chat`'s and `WardrikSlack`'s options, except `owner`, `installations`
      and `identities`.
    * `domains` maps email domains to orgs, and `members` member IDs to users. See
      `WardrikDaemon.ChannelMembers`.
    * `direct` names the agent that answers direct messages, or with `per: member` the agent each
      member's own is made from. See `WardrikDaemon.Direct` and `WardrikDaemon.Direct.Members`.
    * Without `token`, a token per workspace is kept in the vault.
    * A channel serves the deployment's org unless `orgs` says otherwise.
  """

  alias WardrikDaemon.Config.Options

  @types %{"slack" => WardrikSlack}
  @managed [:owner, :installations, :identities, :direct]

  @members [
    members: [
      type: {:map, :string, {:custom, WardrikDaemon.ChannelMembers, :user, []}},
      default: %{},
      doc: "The daemon user each chat member acts as, by member ID."
    ],
    domains: [
      type:
        {:map, {:custom, WardrikDaemon.ChannelMembers, :domain, []},
         {:custom, WardrikDaemon.ChannelMembers, :org, []}},
      default: %{},
      doc: "The org each email domain's members are users in, as `ana@acme.com` is `acme/@ana`."
    ],
    direct: [
      type: {:custom, __MODULE__, :direct, []},
      doc:
        "The agent, by name, that answers direct messages, or `{agent: NAME, per: member}` for an agent per member. None unless set."
    ]
  ]

  @doc "Returns the channels `section` names, as Wardrik's `:channels` option takes them, serving `org`'s agents."
  @spec read(map(), String.t()) :: {:ok, keyword()} | {:error, String.t()}
  def read(section, org) do
    Options.load_modules([Req.Steps])
    Options.each(section, &channel(&1, &2, org))
  end

  defp channel(name, %{"type" => type} = channel, org) do
    path = "channels.#{name}"

    with :ok <- validate_name(name, path),
         {:ok, adapter} <- resolve_type(type, path),
         {:ok, opts} <-
           channel
           |> Map.delete("type")
           |> Options.validate(schema(adapter), path) do
      {members, opts} = Keyword.split(opts, Keyword.keys(@members))

      identities =
        {WardrikDaemon.ChannelMembers, members: members[:members], domains: members[:domains]}

      {:ok,
       {adapter,
        build_installations(opts) ++
          [owner: org, identities: identities] ++ place_direct(members[:direct]) ++ opts}}
    end
  end

  defp channel(name, _channel, _org),
    do: {:error, "channels.#{name}.type: is the kind of channel: slack"}

  defp schema(adapter),
    do:
      Options.public(Wardrik.Chat.Channel.schema(), @managed) ++
        Options.public(adapter.schema(), @managed) ++ @members

  @doc false
  @spec direct(term()) :: {:ok, {module(), keyword()}} | {:error, String.t()}
  def direct(%{"agent" => name, "per" => "member"} = direct) when map_size(direct) == 2,
    do: answer_with(WardrikDaemon.Direct.Members, name)

  def direct(name) when is_binary(name), do: answer_with(WardrikDaemon.Direct, name)

  def direct(_other),
    do: {:error, "is an agent's name, or {agent: NAME, per: member} for an agent per member"}

  defp answer_with(module, name) do
    if WardrikDaemon.AgentRecords.name?(name),
      do: {:ok, {module, name: name}},
      else: {:error, "is an agent's name: letters, digits, _, . and -, at most 64"}
  end

  defp place_direct(nil), do: []
  defp place_direct(direct), do: [direct: direct]

  defp build_installations(opts) do
    if is_binary(opts[:token]), do: [], else: [installations: :stored]
  end

  defp validate_name(name, path) do
    if Regex.match?(~r/\A[a-z][a-z0-9-]*\z/, name) and name not in ~w(shell ssh terminal oauth),
      do: :ok,
      else:
        {:error,
         "#{path}: isn't a channel's name: lower-case letters, digits and -, starting with a letter"}
  end

  defp resolve_type(type, path) do
    case Map.fetch(@types, type) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, "#{path}.type: is the kind of channel: slack"}
    end
  end
end
