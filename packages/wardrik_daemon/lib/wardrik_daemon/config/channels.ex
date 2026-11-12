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
    * Without `token`, a token per workspace is kept in the vault.
    * A channel serves the deployment's org unless `orgs` says otherwise.
  """

  alias WardrikDaemon.Config.Options

  @types %{"slack" => WardrikSlack}
  @managed [:owner, :installations, :identities]

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
    ]
  ]

  @doc "Returns the channels `section` names, as Wardrik's `:channels` option takes them, serving `org`'s agents."
  @spec read(map(), String.t()) :: {:ok, keyword()} | {:error, String.t()}
  def read(section, org) do
    Options.loaded([Req.Steps])
    Options.each(section, &channel(&1, &2, org))
  end

  defp channel(name, %{"type" => type} = channel, org) do
    path = "channels.#{name}"

    with :ok <- named(name, path),
         {:ok, adapter} <- typed(type, path),
         {:ok, opts} <- Options.validate(Map.delete(channel, "type"), schema(adapter), path) do
      {members, opts} = Keyword.split(opts, Keyword.keys(@members))

      identities =
        {WardrikDaemon.ChannelMembers, members: members[:members], domains: members[:domains]}

      {:ok, {adapter, added(opts) ++ [owner: org, identities: identities] ++ opts}}
    end
  end

  defp channel(name, _channel, _org),
    do: {:error, "channels.#{name}.type: is the kind of channel: slack"}

  defp schema(adapter),
    do:
      Options.public(Wardrik.Chat.Channel.schema(), @managed) ++
        Options.public(adapter.schema(), @managed) ++ @members

  defp added(opts) do
    if is_binary(opts[:token]), do: [], else: [installations: :stored]
  end

  defp named(name, path) do
    if Regex.match?(~r/\A[a-z][a-z0-9-]*\z/, name) and name not in ~w(shell ssh terminal oauth),
      do: :ok,
      else:
        {:error,
         "#{path}: isn't a channel's name: lower-case letters, digits and -, starting with a letter"}
  end

  defp typed(type, path) do
    case Map.fetch(@types, type) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, "#{path}.type: is the kind of channel: slack"}
    end
  end
end
