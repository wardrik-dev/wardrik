# wardrik_slack

[Wardrik](../wardrik) in Slack: the [wardrik_channel](../wardrik_channel)
adapter for a Slack app of Wardrik's own, in each workspace it is installed in.
Agents answer in threads, and notices of what they are doing are posted in a
room, with Approve and Deny buttons that answer the calls an agent waits on.

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
    token: ${SLACK_BOT_TOKEN}                 # the bot token, with chat:write
    signing_secret: ${SLACK_SIGNING_SECRET}   # what Slack signs its requests with

notify:
  ops:
    channel: slack
    room: "#ops"
    approvers: ["@maria", "jon@example.com"]
```

A call that waits on a person reaches the room with its arguments and the
policy's question, and pressing Approve or Deny answers it. Slack sends the
app's events and presses over HTTP, signed with `signing_secret`, which the
host serves under `/v1/channels/slack/` and hands to
`WardrikChannel.request/2`. `approvers` names who may press them, by `@handle`,
email address or Slack user id; anyone in the room may without it. An email
address needs the app's `users:read.email` scope.

For testing without a public address, `app_token`, an app-level token with
`connections:write`, has them arrive over Socket Mode instead, a connection the
node opens out to Slack. That app should be Wardrik's alone: Slack spreads an
app's Socket Mode envelopes across every connection open for it.

`token` installs the app in the one workspace it reaches. To install one app in
many workspaces, one for each owner, name its `client_id` and `client_secret`
instead. Your `WardrikChannel.Installations` keeps each workspace's token and
approvers; see `WardrikSlack.Install`.
