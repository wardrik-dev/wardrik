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

In this repository, `mix wardrik` in [wardrik_daemon](../wardrik_daemon)
starts an agent and attaches the TUI to it. `WardrikTUI.SSH` is the session
an SSH server of your own runs.

`WardrikConsole` writes an agent's events to a plain terminal a line at a
time, as the `wardrik` command does; see [the console](guides/console.md).
