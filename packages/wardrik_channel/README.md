# wardrik_channel

Chat media [Wardrik](../wardrik) agents are reached through, such as Slack:
the behaviour each one's adapter implements, and a
[notify](../wardrik/guides/notify.md) target that posts notices in a room of one.

```elixir
def deps do
  [{:wardrik_channel, "~> 0.1.0"}]
end
```

A *channel* is one configured instance of an adapter, under a name of the
deployment's own, such as one Slack app, installed in one workspace or many,
and a *room* is a place in a workspace. In the daemon, `config.yaml` names
them, a channel's `token` installs it in the workspace it reaches, and the
rest of each channel's settings are its adapter's:

```yaml
channels:
  slack:
    type: slack
    token: ${SLACK_BOT_TOKEN}
    signing_secret: ${SLACK_SIGNING_SECRET}
  globex-slack:
    type: slack
    token: ${GLOBEX_SLACK_BOT_TOKEN}

notify:
  ops:
    channel: slack
    room: "#ops"
```

An adapter is a package of its own, such as
[wardrik_slack](../wardrik_slack), which a host names by the type a
channel's settings give, as the daemon names `WardrikSlack` by `slack`, and
attaches the channels to its `Wardrik.Host`:

```elixir
{:ok, settings} = WardrikChannel.config(yaml["channels"], %{"slack" => WardrikSlack})

host =
  WardrikChannel.attach(host,
    channels: settings[:channels],
    installations: installations
  )
```

A host keeps the workspaces each channel is installed in, as its
`WardrikChannel.Installations` say. Each holds its token and who decides
there. The host serves what each medium sends at `/v1/channels/`, and hands it
to `WardrikChannel.request/2`. In a workspace, a channel offers the agents
whose definitions name it, of the owner it was installed for.

Where your people never edit a definition, word what a room says with
`offering:` and `deciding:`. See `WardrikChannel` for the callbacks.
