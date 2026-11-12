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
              Socket Mode, with no public address. For testing. See `WardrikSlack.Socket`.
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
  Slack for Wardrik. Agents answer in threads, and ask there with Approve and Deny buttons.

      config :my_app, MyApp.AgentRuntime,
        channels: [
          slack:
            {WardrikSlack,
             token: "xoxb-...",
             signing_secret: "...",
             owner: "acme",
             identities: {MyApp.ChatMembers, []}}
        ]

  ## Options

  Takes `Wardrik.Chat`'s options, with the bot token (`xoxb-...`) as `:token`, and these:

  #{NimbleOptions.docs(@schema)}

  ## In the thread

    * While an agent works, the thread shows what it's doing.
    * A message the agent takes gets :eyes:, then :white_check_mark: once answered.
  """

  use Wardrik.Chat

  alias Wardrik.Chat.Channel
  alias Wardrik.Chat.Install
  alias Wardrik.Chat.Outbound
  alias Wardrik.Chat.Workspace
  alias WardrikSlack.API
  alias WardrikSlack.Blocks
  alias WardrikSlack.Messages

  @doc "Returns the options it takes beyond `Wardrik.Chat`'s, as a `NimbleOptions` schema."
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @impl Wardrik.Channel
  def request(request, opts),
    do: __MODULE__ |> Wardrik.Chat.channel(opts) |> WardrikSlack.HTTP.request(request)

  @impl Wardrik.Chat
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

  Without `:token`, the per-workspace tokens aren't checked.
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
  @impl Wardrik.Chat
  def install_url(%Install{owner: owner, return_to: return_to}, channel),
    do: WardrikSlack.Install.url(channel, owner, return_to: return_to)

  @doc "Adds the app to a workspace once Slack sends someone back. See `WardrikSlack.Install.installed/3`."
  @impl Wardrik.Chat
  def installed(%Install{owner: owner, query: query}, channel),
    do: WardrikSlack.Install.installed(channel, owner, query)

  @doc """
  Uninstalls the app from `workspace` and forgets the workspace.

  The workspace is forgotten even if Slack refuses. Slack confirms with an `app_uninstalled` event.
  """
  @impl Wardrik.Chat
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

  @impl Wardrik.Chat
  def deliver(%Outbound{installation: installation} = outbound, channel) do
    workspace = %Workspace{channel: channel, installation: installation}

    if shown?(workspace, outbound),
      do: {:skip, "but its turn was in a Slack thread, which shows it"},
      else: with({:ok, _posted} <- posted(workspace, outbound), do: :ok)
  end

  # A turn in one of the workspace's threads is answered there; its notice would repeat it.
  defp shown?(workspace, %Outbound{body: {:notice, notice}}),
    do: Workspace.thread?(workspace, notice.conversation)

  defp shown?(_workspace, _outbound), do: false

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
