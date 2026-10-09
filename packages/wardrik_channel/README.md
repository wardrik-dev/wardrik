# wardrik_channel

Chat media [Wardrik](../wardrik) agents are reached through, such as Slack:
the behaviour each one's adapter implements, and a
[wardrik_notify](../wardrik_notify) target that posts notices in a room of one.

```elixir
def deps do
  [{:wardrik_channel, "~> 0.1.0"}]
end
```

A *channel* is one configured instance of an adapter, under a name of the
deployment's own, and a *room* is a place in it. In the daemon, `config.yaml`
names them, and the rest of each channel's settings are its adapter's:

```yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    app_token: ${SLACK_APP_TOKEN}
  globex-slack:
    type: slack
    token: ${GLOBEX_SLACK_BOT_TOKEN}

notify:
  ops:
    channel: slack
    room: "#ops"
```

An adapter is a package of its own, such as
[wardrik_slack](../wardrik_slack), which names itself in its application's
environment, so a release that holds it finds it by its type:

```elixir
# mix.exs of an adapter
def application, do: [env: [wardrik_channels: [teams: MyTeams]]]
```

See `WardrikChannel` for the callbacks.
