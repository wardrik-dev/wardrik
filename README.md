# WardrikVault

Keeps credentials sealed at rest, for [WardrikCore](https://hexdocs.pm/wardrik_core) agents' tools.

## Install

```elixir
{:wardrik_vault, "~> 0.1.0-rc.2"}
```

## Start it

```elixir
store = WardrikStore.ETS.new(name: MyApp.Store)

children = [
  {WardrikStore, store},
  {WardrikVault, name: MyApp.Vault, store: store, keys: [System.fetch_env!("VAULT_KEY")]}
]
```

- Make a key with `WardrikVault.generate_key/0`. Values are sealed with AES-256-GCM.
- The first key seals. Any key unseals. To rotate, put a new key first.

## Use it

```elixir
jon = %WardrikCore.Principal{id: "user:jon"}

{:ok, vsn} =
  WardrikVault.put(MyApp.Vault, %WardrikVault.Secret{principal: jon, name: "github", value: "ghp_..."})

WardrikVault.fetch(MyApp.Vault, jon, "github")
#=> {:ok, "ghp_..."}

WardrikVault.list(MyApp.Vault)
#=> [{"user:jon", "github", :secret}]
```

Names aren't sealed. Anyone who can read the store sees who holds which name.

## Give it to agents

```elixir
WardrikCore.start_agent(
  agent_id: "digest",
  model: "anthropic:claude-haiku-4-5",
  principal: jon,
  credentials: {WardrikVault, MyApp.Vault}
)
```

A tool reads only what the agent's user holds.

## Your app's own secrets

Keep them under `WardrikVault.deployment/0`, and name them in options as `{:secret, name}`:

```elixir
{:ok, _vsn} =
  WardrikVault.put(MyApp.Vault, %WardrikVault.Secret{
    principal: WardrikVault.deployment(),
    name: "SLACK_SIGNING_SECRET",
    value: secret
  })

WardrikVault.value(MyApp.Vault, {:secret, "SLACK_SIGNING_SECRET"})
#=> {:ok, "8f14..."}
```

No agent's tools can read them.

## OAuth tokens

Give the vault a `WardrikVault.Grants` module, such as [WardrikOAuth](https://hexdocs.pm/wardrik_oauth),
to refresh tokens and start sign-ins:

```elixir
{WardrikVault, name: MyApp.Vault, store: store, keys: keys, grants: {WardrikOAuth, MyApp.OAuth}}
```
