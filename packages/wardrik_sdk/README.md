# wardrik_sdk

[Wardrik](../wardrik) with every package: the tools, the stores, the vault and
OAuth, policies and notices, the HTTP API, the TUI and the daemon, in one
dependency.

```elixir
def deps do
  [{:wardrik_sdk, "~> 0.1.0"}]
end
```

It adds `mix wardrik`, which starts an agent with the tools the packages ship
and attaches the TUI to it:

```sh
mix wardrik
mix wardrik --model anthropic:claude-sonnet-5
mix wardrik --mcp github --mcp linear
mix wardrik --policy MyApp.Policy --user jon --org acme
```

`mix help wardrik` lists its options. Depend on the packages you use instead
when you know which they are; the [package index](../../README.md#packages)
says what each one does.
