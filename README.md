# WardrikChannel

Talk to [Wardrik](https://hexdocs.pm/wardrik) agents from chat apps, such as Slack. This package
holds what every chat adapter shares: rooms, threads, replies and approvals.

## Install

Add an adapter, such as [WardrikSlack](https://hexdocs.pm/wardrik_slack). It brings this package in.

```elixir
{:wardrik_slack, "~> 0.1.0-rc.2"}
```

To write your own adapter, depend on `{:wardrik_channel, "~> 0.1.0-rc.2"}`. See `WardrikChannel`.

## Set up

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

Say who each chat member is in your app. A member you return an error for is told the error.

```elixir
defmodule MyApp.ChatMembers do
  @behaviour WardrikChannel.Identities

  @impl true
  def identify(request, _opts) do
    case MyApp.Accounts.by_chat(request.channel, request.workspace, request.member) do
      %MyApp.User{} = user -> {:ok, Wardrik.principal(user.id)}
      nil -> {:error, "Link your Slack account in MyApp first."}
    end
  end
end
```

Serve the chat app's requests with `Wardrik.HTTP`. It answers `POST /v1/channels/slack/...`.
Then list the channel in an agent's definition:

```elixir
Wardrik.Agent.define(scope, "agt_01JF8X5RQ2",
  model: "anthropic:claude-haiku-4-5",
  channels: ["slack"]
)
```

## In the chat

- Invite the bot into a room. If one agent is offered, it answers there. With several, someone picks.
- Mention the bot. The agent answers in a thread.
- Reply in the thread. No mention needed.
- Each thread is its own conversation, such as `"slack.T0123.C024BE91L.1696.1234"`.
- Calls the agent waits on are posted in the thread to approve or deny.

## Access

Your authorizer decides what chat members may read, ask and decide. Requests from a chat have
`actor: {:channel, "slack"}`. Their `context` has `:installation`, and `:asked_by` when deciding.

```elixir
# Whoever asked decides their own calls.
def authorize(%{actor: {:channel, _name}, action: "agent.decide"} = request, _opts) do
  if request.context[:asked_by] == request.principal.id, do: :ok, else: {:error, :forbidden}
end
```

## Many workspaces

Give `installations:` instead of `token:` and `owner:`:

```elixir
installations: :stored                        # kept in Wardrik; needs Wardrik's :vault_keys
installations: {MyApp.ChatInstallations, []}  # your Wardrik.Channel.Installations
```

## Notices

`notify: "slack:#ops"` in a definition posts in `#ops`. The workspace is the one your resolver gives
the agent, as `%Wardrik.Resolved{channels: %{"slack" => "T0123"}}`.
