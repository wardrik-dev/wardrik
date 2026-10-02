# wardrik_tui

A terminal UI for [Wardrik](../wardrik) agents: the conversation as it
streams, the tool calls of each turn as a tree, the calls waiting on you, and
a panel of every agent in the fleet.

```elixir
def deps do
  [{:wardrik_tui, "~> 0.1.0"}]
end
```

The daemon serves it over SSH once `~/.config/wardrik/ssh/authorized_keys`
lists a key, and each connection is a session of its own:

```sh
ssh -p 2222 jon@localhost      # or: wardrik attach
```

In a project of your own, `mix wardrik` from [wardrik_sdk](../wardrik_sdk)
starts an agent and attaches the TUI to it. `WardrikTUI.SSH` is the session
an SSH server of your own runs.
