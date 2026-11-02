defmodule WardrikSlack do
  @schema NimbleOptions.new!(
            signing_secret: [
              type: {:or, [:string, nil]},
              doc: """
              Takes Slack's requests over HTTP, at `/v1/channels/{channel}/events` and
              `/v1/channels/{channel}/actions`. See `WardrikSlack.HTTP`.
              """
            ],
            app_token: [
              type: {:or, [:string, nil]},
              doc: """
              An app-level token, `xapp-...`, with `connections:write`. Takes Slack's requests over
              Socket Mode instead, with no public address. For testing. See `WardrikSlack.Socket`.
              """
            ],
            client_id: [
              type: {:or, [:string, nil]},
              doc:
                "Adds one app to many workspaces, with `:client_secret`. See `WardrikSlack.Install`."
            ],
            client_secret: [type: {:or, [:string, nil]}, doc: "The app's client secret."],
            redirect_uri: [
              type: :string,
              doc: "Where Slack sends someone once they've added the app."
            ],
            req_options: [
              type: :keyword_list,
              default: [],
              doc: "Merged into every request to Slack."
            ]
          )

  @moduledoc """
  Slack for Wardrik. A `WardrikChannel` adapter for a Slack app of your own.

  Agents answer in threads. Before a call they can't make alone, they ask there, with Approve and
  Deny buttons.

      config :my_app, MyApp.AgentRuntime,
        channels: [
          slack:
            {WardrikSlack,
             token: "xoxb-...",
             signing_secret: "...",
             owner: "acme",
             identities: {MyApp.ChatMembers, []}}
        ]

  It speaks Slack's protocol. Who each member is, what they may do, and where an agent's notices
  go are `WardrikChannel`'s, as for any channel.

  ## Options

  Takes `WardrikChannel`'s options, such as `:identities`. Its `:token` is the bot token,
  `xoxb-...`. And these:

  #{NimbleOptions.docs(@schema)}

  Over Socket Mode, give Wardrik a Slack app of its own. Slack spreads an app's events across
  every open connection.

  ## In the thread

    * While an agent works, the thread shows what it's doing as the app's status.
    * A message the agent takes gets :eyes:, then :white_check_mark: once it's answered.
    * A call the agent waits on is posted with Approve and Deny. Your authorizer decides who may
      press them.
  """

  use WardrikChannel

  alias WardrikChannel.Channel
  alias WardrikChannel.Install
  alias WardrikChannel.Outbound
  alias WardrikChannel.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Blocks
  alias WardrikSlack.Messages

  @doc "Returns the options it takes beyond `WardrikChannel`'s, as a `NimbleOptions` schema."
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @impl Wardrik.Channel
  def request(request, opts),
    do: __MODULE__ |> WardrikChannel.channel(opts) |> WardrikSlack.HTTP.request(request)

  @impl WardrikChannel
  def children(%Channel{options: options} = channel) do
    NimbleOptions.validate!(options, @schema)

    socket =
      if Keyword.has_key?(options, :app_token), do: [{WardrikSlack.Socket, channel}], else: []

    [{Task.Supervisor, name: tasks(channel)} | socket]
  end

  @doc """
  Checks a channel's tokens with Slack.

      WardrikSlack.check(token: "xoxb-...", app_token: "xapp-...")
      #=> {:ok, "posts as @wardrik in Acme"}

      WardrikSlack.check(token: "xoxb-wrong")
      #=> {:error, "Slack refused its token: \"invalid_auth\""}

  Checks `:token` with `auth.test`, and `:app_token` by opening a Socket Mode URL. Without
  `:token`, the channel keeps a token for each workspace, and those aren't checked.
  """
  @spec check(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def check(opts) do
    req_options = [retry: false] ++ Keyword.get(opts, :req_options, [])

    with {:ok, said} <- bot(opts[:token], req_options),
         :ok <- app(opts[:app_token], req_options),
         do: {:ok, said}
  end

  defp bot(nil, _req_options), do: {:ok, "keeps a token for each workspace it's added to"}

  defp bot(token, req_options) do
    case API.post("auth.test", token: token, body: %{}, req_options: req_options) do
      {:ok, %{"user" => user, "team" => team}} -> {:ok, "posts as @#{user} in #{team}"}
      {:error, why} -> {:error, "Slack refused its token: #{inspect(why)}"}
    end
  end

  defp app(nil, _req_options), do: :ok

  defp app(token, req_options) do
    case API.post("apps.connections.open", token: token, body: %{}, req_options: req_options) do
      {:ok, _url} -> :ok
      {:error, why} -> {:error, "Slack refused its app_token: #{inspect(why)}"}
    end
  end

  @doc "Returns the name of the task supervisor that handles what Slack sends the channel."
  @spec tasks(Channel.t()) :: atom()
  def tasks(%Channel{wardrik: wardrik, name: name}),
    do: Module.concat([wardrik, "Channels", name, "Tasks"])

  @doc "Returns the URL where someone acting for `owner` adds the app. See `WardrikSlack.Install.url/3`."
  @impl WardrikChannel
  def install_url(%Install{owner: owner, return_to: return_to}, channel),
    do: WardrikSlack.Install.url(channel, owner, return_to: return_to)

  @doc "Adds the app to a workspace once Slack sends someone back. See `WardrikSlack.Install.installed/3`."
  @impl WardrikChannel
  def installed(%Install{owner: owner, query: query}, channel),
    do: WardrikSlack.Install.installed(channel, owner, query)

  @doc """
  Uninstalls the app from `workspace` and forgets the workspace.

  The workspace is forgotten even if Slack refuses. Slack confirms with an `app_uninstalled` event.
  """
  @impl WardrikChannel
  def uninstall(workspace, channel) do
    with {:ok, installation} <- Channel.installation(channel, workspace) do
      credentials = %{
        client_id: channel.options[:client_id],
        client_secret: channel.options[:client_secret]
      }

      _asked =
        API.read("apps.uninstall",
          token: installation.token,
          params: credentials,
          req_options: API.req_options(channel)
        )
    end

    Channel.uninstall(channel, workspace)
  end

  @impl WardrikChannel
  def deliver(%Outbound{installation: installation} = outbound, channel) do
    workspace = %Workspace{channel: channel, installation: installation}

    with {:ok, _posted} <- posted(workspace, outbound), do: :ok
  end

  defp posted(workspace, %Outbound{room: room, thread: thread, body: {:status, label}}),
    do:
      API.post_in(workspace, "assistant.threads.setStatus", %{
        channel_id: room,
        thread_ts: thread,
        status: label
      })

  defp posted(workspace, %Outbound{room: room, body: {:stopped, answering}} = outbound) do
    :ok = Messages.stopped(workspace, room, answering)
    posted(workspace, %{outbound | body: {:status, ""}})
  end

  defp posted(workspace, %Outbound{room: room, body: {:reply, text, answering}} = outbound) do
    with {:ok, posted} <- message(workspace, outbound, reply(text)) do
      :ok = Messages.answered(workspace, room, answering)
      {:ok, posted}
    end
  end

  defp posted(workspace, %Outbound{body: {:waiting, calls}} = outbound),
    do: message(workspace, outbound, WardrikSlack.Waiting.message(calls))

  defp posted(workspace, %Outbound{body: {:failed, reason}} = outbound),
    do: message(workspace, outbound, %{text: ":warning: It stopped with an error: #{reason}"})

  defp posted(workspace, %Outbound{body: {:notice, notice}} = outbound),
    do: message(workspace, outbound, WardrikSlack.Notices.message(notice))

  defp posted(workspace, %Outbound{body: {:said, text}} = outbound),
    do: message(workspace, outbound, %{text: text, blocks: [Blocks.context(text)]})

  defp reply(""), do: %{text: "_It answered nothing._"}
  defp reply(text), do: %{text: Blocks.clip(text, 3_000), blocks: [Blocks.markdown(text)]}

  defp message(workspace, %Outbound{room: room, thread: nil}, message),
    do: API.post_in(workspace, "chat.postMessage", Map.put(message, :channel, room))

  defp message(workspace, %Outbound{room: room, thread: thread}, message),
    do:
      API.post_in(
        workspace,
        "chat.postMessage",
        Map.merge(message, %{channel: room, thread_ts: thread})
      )
end
