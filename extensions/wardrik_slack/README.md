# WardrikSlack

Connect Wardrik agents to Slack threads and display approval buttons for tool calls.

## Make the Slack app

At [api.slack.com/apps](https://api.slack.com/apps), choose **Create New App** › **From a
manifest**, and paste a manifest below.

### Socket Mode, for testing

Needs no public address.

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

- **Install to Workspace**, then copy the **Bot User OAuth Token** (`xoxb-...`). This is `token`.
- Under **Basic Information › App-Level Tokens**, make a token with `connections:write`
  (`xapp-...`). This is `app_token`.
- Give Wardrik its own Slack app. Slack spreads an app's events across every open connection.

### HTTP, for production

Use the manifest above with these `settings`, and your app's address:

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

- `slack` in each URL is the channel's name in your config.
- Slack checks the events URL when you save, so your app must be running there.
- Copy the **Signing Secret** from **Basic Information**. This is `signing_secret`.

## Try it locally

From a checkout of this repository, install dependencies and run the Socket Mode example:

```sh
mix deps.get

SLACK_BOT_TOKEN=xoxb-... SLACK_APP_TOKEN=xapp-... ANTHROPIC_API_KEY=sk-ant-... \
  mix run --no-halt examples/socket_mode.exs
```

Then `/invite @Wardrik` into a channel and ask `@Wardrik what time is it?`. Approve the clock.

## Set up

Application integration fragments: first configure a [Wardrik runtime](https://hexdocs.pm/wardrik/running-wardrik.html) named `MyApp.AgentRuntime`.

```elixir
{:wardrik_slack, "~> 0.1.0-rc.4"}
```

In `config/runtime.exs`:

```elixir
config :my_app, MyApp.AgentRuntime,
  channels: [
    slack:
      {WardrikSlack,
       token: System.fetch_env!("SLACK_BOT_TOKEN"),
       signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
       owner: "acme",
       identities: {MyApp.ChatMembers, []}}
  ]
```

See `Wardrik.Chat` for `identities`, rooms, threads and
approvals, and `WardrikSlack` for every option.

Phoenix endpoint and router fragments: implement `MyAppWeb.WardrikSession` as a `Wardrik.HTTP.Authenticator`.
Slack verifies the raw request body. Configure the endpoint parser before mounting the router:

```elixir
plug(Plug.Parsers,
  parsers: [:json, :urlencoded],
  json_decoder: JSON,
  body_reader: Wardrik.HTTP.body_reader()
)

forward("/", Wardrik.HTTP,
  wardrik: MyApp.AgentRuntime,
  authenticator: {MyAppWeb.WardrikSession, []}
)
```

List the channel in an agent's definition, then invite the app into a Slack channel:

```elixir
scope = MyApp.AgentRuntime.as("maria")

Wardrik.Agent.define(scope, "agt_01JF8X5RQ2",
  model: "anthropic:claude-haiku-4-5",
  channels: ["slack"]
)
```

## Notices

Post to a room when an agent finishes, fails or waits on someone:

```elixir
scope = MyApp.AgentRuntime.as("maria")

Wardrik.Agent.define(scope, "agt_01JF8Y2DGS",
  model: "anthropic:claude-haiku-4-5",
  notify: %{to: ["slack:#updates"], on: ["finished", "failed"]}
)
```

- It posts in the workspace your resolver gives the agent, as `channels: %{"slack" => "T0123"}`.
- The app posts in any public channel. Invite it into private ones.
- It never answers its own posts.

## Many workspaces

Replace the `slack` entry in the runtime configuration with this fragment:

```elixir
[
  slack:
    {WardrikSlack,
     client_id: System.fetch_env!("SLACK_CLIENT_ID"),
     client_secret: System.fetch_env!("SLACK_CLIENT_SECRET"),
     redirect_uri: "https://agents.example.com/slack/installed",
     signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
     installations: :stored,
     identities: {MyApp.ChatMembers, []}}
]
```

Tokens are sealed in Wardrik's vault, so Wardrik needs `:vault_keys`. See `WardrikSlack.Install`.
