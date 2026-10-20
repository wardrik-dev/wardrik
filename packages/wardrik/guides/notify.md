# Notices

Tells people what Wardrik agents are doing when nobody is
watching: a turn that waits on a question, one that failed, and, if you ask
for it, what a turn answered. It sends to webhooks, to a room in a chat
channel such as Slack through [wardrik_channel](../../wardrik_channel), and a
target of your own is a module.

In the daemon, `config.yaml` names the targets and an agent file routes its
agent to them:

```yaml
# ~/.config/wardrik/config.yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}                 # the Slack app's bot token
    signing_secret: ${SLACK_SIGNING_SECRET}   # for Approve and Deny buttons

notify:
  ops:
    channel: slack
    room: "#ops"
    approvers: ["@maria"]           # who may press them; anyone in #ops without it
  audit:
    webhook:
      url: https://hooks.example.com/wardrik
      secret: ${WARDRIK_WEBHOOK_SECRET}
```

```yaml
# in an agent file
notify: {to: [ops, "slack:#updates"], on: [parked, failed, finished]}
```

`slack:#updates` is a room of a channel, written `channel:room`, which needs
no target: where the channel offers the agent's org, it is posted in the
workspace the channel is installed in for the agent's own owner, so each org's
agents post in their own, and one whose owner has none posts nothing, with a
warning in the log. The bot must be able to post
in the room: in Slack, invited into it, or the app holding `chat:write.public`.
It names nobody to answer: who may is what the host's issuer allows.

One process in the cluster sends the notices, reading each agent's route from
its definition as its events come. It keeps its place in the agents' logs, so
after a restart, on any node, it carries on from there: a notice whose
delivery was cut short comes again, and a receiver tells a repeat by its
`agent`, `event` and `at`.

Outside the daemon, a host attaches it with its targets, and a target of your
own is a module; see `WardrikNotify`. The rooms are those of the channels
`WardrikChannel.attach/2` runs, in the workspaces their installations hold:

```elixir
wardrik =
  Wardrik.new(store: store, issuer: %MyApp.Issuer{})
  |> WardrikNotify.attach(
    targets: [audit: {WardrikNotify.Webhook, url: "https://hooks.example.com/wardrik"}]
  )
  |> WardrikChannel.attach(channels: [slack: {WardrikSlack, options}], installations: installations)
```

It follows every agent's log as the deployment itself,
`Wardrik.Principal.deployment/0`, so the host's issuer gives `deployment`
`agent.events` on `*/agent/*`; see `Wardrik.Issuer`. A host whose issuer does
not fails to start it.
