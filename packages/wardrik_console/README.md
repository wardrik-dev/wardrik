# wardrik_console

[Wardrik](../wardrik)'s agents on a plain terminal: their events, streamed
markdown and tables, written a line at a time and never redrawn. It is what
the `wardrik` command writes with, and works anywhere a program writes to a
terminal or a log.

```elixir
def deps do
  [{:wardrik_console, "~> 0.1.0"}]
end
```

`WardrikConsole` lists what it renders: markdown as it streams, the tables the
command prints, and an agent's events as they arrive.
