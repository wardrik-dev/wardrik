# WardrikSlack

Slack for Wardrik. Agents answer in threads, and ask there before a call they can't make alone.

> **maria:** @Wardrik what time is it on the server? :eyes:
> ↳ **Wardrik:** Waiting on @maria to approve `clock`.
> **Wardrik**, to maria: `clock`, from a thread in #ops. `[Approve]` `[Deny]`
> ↳ **Wardrik:** Approved by maria.
> ↳ **Wardrik:** It's 14:02 UTC.

## Make the Slack app

At [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App**, then **From a
manifest**. Pick your workspace and paste one of the manifests below. Change `Wardrik` to the
name your team will see.

### For testing, over Socket Mode

Socket Mode needs no public address. Your app opens the connection to Slack.

```yaml
display_information:
  name: Wardrik
  description: Agents that answer in threads, and ask before they act.
features:
  app_home:
    home_tab_enabled: false
    messages_tab_enabled: true
    messages_tab_read_only_enabled: true
  bot_user:
    display_name: Wardrik
    always_online: true
oauth_config:
  scopes:
    bot:
      - channels:history
      - channels:read
      - chat:write
      - chat:write.public
      - groups:history
      - groups:read
      - reactions:write
      - users:read
      - users:read.email
settings:
  event_subscriptions:
    bot_events:
      - app_uninstalled
      - channel_left
      - group_left
      - member_joined_channel
      - message.channels
      - message.groups
      - tokens_revoked
  interactivity:
    is_enabled: true
  org_deploy_enabled: false
  socket_mode_enabled: true
  token_rotation_enabled: false
```

Then:

1. Choose **Install to Workspace**. Copy the **Bot User OAuth Token** (`xoxb-...`) from
   **OAuth & Permissions**. This is `token`.
2. Under **Basic Information › App-Level Tokens**, make a token with the `connections:write`
   scope (`xapp-...`). This is `app_token`.

Give Wardrik a Slack app of its own for Socket Mode. Slack spreads an app's events across every
open connection.

### For production, over HTTP

Slack sends events to your app's public address. Use the manifest above, with these `settings`.
Change `agents.example.com` to your address:

```yaml
settings:
  event_subscriptions:
    request_url: https://agents.example.com/v1/channels/slack/events
    bot_events:
      - app_uninstalled
      - channel_left
      - group_left
      - member_joined_channel
      - message.channels
      - message.groups
      - tokens_revoked
  interactivity:
    is_enabled: true
    request_url: https://agents.example.com/v1/channels/slack/actions
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
```

`slack` in each URL is the channel's name in your Wardrik config. Slack checks the events URL
when you save, so your app must already be running there.

Copy the **Signing Secret** from **Basic Information › App Credentials**. This is
`signing_secret`.

## Try it locally

From this repository, with the Socket Mode tokens and a model key:

```sh
SLACK_BOT_TOKEN=xoxb-... SLACK_APP_TOKEN=xapp-... ANTHROPIC_API_KEY=sk-ant-... \
  mix run --no-halt examples/socket_mode.exs
```

This starts Wardrik in memory with the agent `acme/assistant`. The agent may read a clock once
someone approves it.

1. In Slack, `/invite @Wardrik` into a channel.
2. Mention it: `@Wardrik what time is it?`

Set `SLACK_APPROVERS=@you` to name the approvers. Without it, whoever asked approves.

## Wire it up

```elixir
def deps do
  [
    {:wardrik_slack, "~> 0.1.0-rc.2"}
  ]
end
```

Add the channel to your Wardrik, under a name of your choice:

```elixir
config :my_app, MyApp.AgentRuntime,
  channels: [
    slack:
      {WardrikSlack,
       token: System.fetch_env!("SLACK_BOT_TOKEN"),
       signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
       owner: "acme",
       approvers: ["@maria", "jon@example.com"]}
  ]
```

See `WardrikSlack` for every option. People in Slack act with the channel as their actor,
`{:channel, "slack"}`, and Wardrik's `:authorizer` decides what they may do. See
`WardrikChannel.Workspace`.

Over HTTP, serve it with `Wardrik.HTTP`. Slack signs the exact bytes it sends, so if your app
parses bodies first, keep the raw body:

```elixir
plug Plug.Parsers,
  parsers: [:json, :urlencoded],
  json_decoder: JSON,
  body_reader: Wardrik.HTTP.body_reader()

forward "/", Wardrik.HTTP,
  wardrik: MyApp.AgentRuntime,
  authenticator: {MyAppWeb.WardrikSession, []}
```

List the channel in an agent's definition:

```elixir
Wardrik.Agent.define(scope, "acme/triage",
  model: "anthropic:claude-haiku-4-5",
  description: "Triages incidents.",
  channels: ["slack"]
)
```

Invite the app into a Slack channel. If one agent is offered, it answers there from then on:
mention the app, and it replies in a thread under your message. If several are offered, pick
one. See [WardrikChannel](https://hexdocs.pm/wardrik_channel) for rooms, threads and approvals.

## Approvers

Name `approvers` by `@handle`, email address or Slack member ID, or use `:anyone`. Email
addresses need the `users:read.email` scope. Whoever asked for a turn may always decide it.

When an agent waits on a call:

1. Each approver gets the call in the app's **Messages** tab, with a link to its thread.
2. The thread says who it waits on:

   > ↳ **Wardrik:** Waiting on @maria or @jon to approve `create_bill`.

3. The first to answer decides.

If Slack can reach none of the approvers, the call is asked in the thread, with the same buttons.

## Notices

An agent nobody watches, such as one a trigger runs every morning, can post to a room when it
finishes, fails or waits on someone. Route it to `slack:#room`:

```elixir
Wardrik.Agent.define(scope, "acme/digest",
  model: "anthropic:claude-haiku-4-5",
  notify: %{to: ["slack:#updates"], on: ["finished", "failed"]}
)
```

To ask approvers about a parked turn, add a target to your Wardrik's `notify`, and route to it:

```elixir
config :my_app, MyApp.AgentRuntime,
  notify: [targets: [ops: {Wardrik.Notify.Room, channel: "slack", room: "#ops", approvers: ["@maria"]}]]

Wardrik.Agent.define(scope, "acme/triage", model: "anthropic:claude-haiku-4-5", notify: "ops")
```

The notice is posted in the room with Approve and Deny. Each approver also gets it in the
**Messages** tab, with a link. Only the channel's own approvers may decide.

* The app posts in any public channel, since the manifest asks for `chat:write.public`. Invite
  it into private ones.
* It never answers its own posts, so a room where the agent answers every message doesn't loop.

See `Wardrik.Notify` for webhooks and other targets.

## Many workspaces

One app can serve many workspaces, one for each org:

```elixir
slack:
  {WardrikSlack,
   client_id: System.fetch_env!("SLACK_CLIENT_ID"),
   client_secret: System.fetch_env!("SLACK_CLIENT_SECRET"),
   redirect_uri: "https://agents.example.com/slack/installed",
   signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
   installations: :stored}
```

`client_id` and `client_secret` are under **Basic Information**. Set `redirect_uri` under
**OAuth & Permissions**. Each workspace's token is sealed in Wardrik's vault, so Wardrik needs
`:keys`. See `WardrikSlack.Install`.
