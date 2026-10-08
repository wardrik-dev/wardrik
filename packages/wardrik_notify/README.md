# wardrik_notify

Tells people what [Wardrik](../wardrik) agents are doing when nobody is
watching: a turn that waits on a question, one that failed, and, if you ask
for it, what a turn answered. It sends to Slack and to webhooks, and a target
of your own is a module.

```elixir
def deps do
  [{:wardrik_notify, "~> 0.1.0"}]
end
```

In the daemon, `config.yaml` names the targets and an agent file routes its
agent to them:

```yaml
# ~/.config/wardrik/config.yaml
notify:
  ops:
    slack:
      channel: "#ops"
      token: ${SLACK_BOT_TOKEN}         # a bot token with chat:write
      app_token: ${SLACK_APP_TOKEN}     # Socket Mode, for Approve and Deny buttons
  audit:
    webhook:
      url: https://hooks.example.com/wardrik
      secret: ${WARDRIK_WEBHOOK_SECRET}
```

```yaml
# in an agent file
notify: {to: [ops], on: [parked, failed, finished]}
```

A call that waits on a person reaches Slack with its arguments and the
policy's question, and pressing Approve or Deny answers it. The buttons arrive
over Socket Mode, a connection the daemon opens out to Slack, so it needs no
public address and no open port.

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
