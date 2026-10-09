# wardrik_slack

[Wardrik](../wardrik) in Slack: the [wardrik_channel](../wardrik_channel)
adapter for a Slack workspace, through a Slack app of Wardrik's own. Notices of
what agents are doing are posted in a room, with Approve and Deny buttons that
answer the calls an agent waits on.

```elixir
def deps do
  [{:wardrik_slack, "~> 0.1.0"}]
end
```

The package names itself as the adapter `type: slack`, so a release that holds
it reads Slack channels from `config.yaml` without being told more:

```yaml
# ~/.config/wardrik/config.yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}       # the bot token, with chat:write
    app_token: ${SLACK_APP_TOKEN}   # an app-level token with connections:write

notify:
  ops:
    channel: slack
    room: "#ops"
    approvers: ["@maria", "jon@example.com"]
```

A call that waits on a person reaches the room with its arguments and the
policy's question, and pressing Approve or Deny answers it. The presses arrive
over Socket Mode, a connection the daemon opens out to Slack, so it needs no
public address and no open port. `approvers` names who may press them, by
`@handle`, email address or Slack user id; anyone in the room may without it.
An email address needs the app's `users:read.email` scope.

Each Slack workspace is a channel of its own, with an app of its own, which
should be Wardrik's alone: Slack spreads an app's Socket Mode envelopes across
every connection open for it.
