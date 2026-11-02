# WardrikChannel

Lets people talk to [Wardrik](https://hexdocs.pm/wardrik)'s agents from chat apps, such as Slack.
It handles rooms, threads, replies and approvals.

Each chat app has its own adapter package, such as [WardrikSlack](https://hexdocs.pm/wardrik_slack).
This package holds what every adapter shares.

## Install

Add an adapter. It brings this package in.

```elixir
def deps do
  [
    {:wardrik_slack, "~> 0.1.0-rc.2"}
  ]
end
```

To write an adapter of your own, depend on this package directly:

```elixir
{:wardrik_channel, "~> 0.1.0-rc.2"}
```

## Wire it up

A channel is one chat app Wardrik runs, under a name you choose. Give it a token, and the owner
whose agents answer there:

```elixir
defmodule MyApp.AgentRuntime do
  use Wardrik, otp_app: :my_app
end

config :my_app, MyApp.AgentRuntime,
  channels: [
    slack:
      {WardrikSlack,
       token: System.fetch_env!("SLACK_BOT_TOKEN"),
       signing_secret: System.fetch_env!("SLACK_SIGNING_SECRET"),
       owner: "acme",
       approvers: ["@maria"]}
  ]
```

The chat app posts to `POST /v1/channels/slack/{path}`. Serve it with `Wardrik.HTTP`:

```elixir
forward "/", Wardrik.HTTP,
  wardrik: MyApp.AgentRuntime,
  authenticator: {MyAppWeb.WardrikSession, []}
```

List the channel in an agent's definition:

```elixir
scope = MyApp.AgentRuntime.as("acme/@maria")

Wardrik.Agent.define(scope, "acme/triage",
  model: "anthropic:claude-haiku-4-5",
  description: "Triages incidents.",
  channels: ["slack"]
)
```

Then invite the bot into a room:

1. If one agent is offered, it answers in that room from then on. With several, someone picks one.
2. Mention the bot. The agent answers in a thread under your message.
3. Reply in the thread. The agent answers again, no mention needed.

## Threads

Each thread is its own conversation with the agent, with its own history:

```
acme/triage/slack.T0123.C024BE91L.1696.1234
```

People in the workspace act as themselves, as `slack:T0123/U024BE7LH`, with the channel as
their actor, `{:channel, "slack"}`. Wardrik's `:authorizer` decides whether they may read and
message the owner's agents. Its request's `context` holds the `installation`, as
`%{owner: "acme", workspace: "T0123"}`.

Replies are read from the agents' logs. Each room has one process in your cluster, kept in
Wardrik's store. A reply delayed by a restart is still posted.

## Approvals

When an agent waits on a call, the call and its arguments are posted in the thread. When someone
decides it, the authorizer's request `context` also says:

* `approver` - whether they're in `approvers`, as the chat app names people, or `true` for
  everyone with `approvers: :anyone`
* `asked_by` - the principal ID that asked for that turn, where known

An authorizer that allows only approvers and the asker gives the usual rule:

```elixir
def authorize(%{actor: {:channel, _name}, action: "agent.decide", context: context} = request, _opts),
  do: if(context[:approver] || context[:asked_by] == request.principal.id, do: :ok, else: {:error, :forbidden})
```

Anyone refused is told who may decide.

## Many workspaces

`token:` adds the channel to the one workspace that token reaches. To add one app to many
workspaces, such as one per org, give the channel `installations:` instead of `token:`:

```elixir
# Kept in Wardrik: owners in its store, tokens sealed with its :keys
installations: :stored

# Kept by your app, in a module implementing Wardrik.Channel.Installations
installations: {MyApp.ChatInstallations, []}
```

Your adapter's docs list what else it needs, such as Slack's `:client_id`.

## Rooms in the audit

Binding a room is recorded in Wardrik's audit as `wardrik.room.bound`. Unbinding it is recorded as
`wardrik.room.unbound`. Both say who did it.
