# wardrik_notify

Tells people what [Wardrik](../wardrik) agents are doing when nobody is
watching: a turn that waits on a question, one that failed, and, if you ask
for it, what a turn answered. It sends to webhooks, to a room in a chat
channel such as Slack through [wardrik_channel](../wardrik_channel), and a
target of your own is a module.

```elixir
def deps do
  [{:wardrik_notify, "~> 0.1.0"}]
end
```

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
notify: {to: [ops], on: [parked, failed, finished]}
```

A notice is sent once from the node that holds the agent, however many nodes
the cluster has.

Outside the daemon, a host starts it with its targets, and a target of your
own is a module; see `WardrikNotify`:

```elixir
children = [
  Wardrik,
  {WardrikNotify.Supervisor,
   targets: [audit: {WardrikNotify.Webhook, url: "https://hooks.example.com/wardrik"}]}
]
```
