# WardrikVault

Encrypts credentials at rest, for [WardrikCore](https://hexdocs.pm/wardrik_core) agents' tools.

## Install

```elixir
{:wardrik_vault, "~> 0.1.0-rc.3"}
```

## Start the vault

Run in a fresh IEx session:

```elixir
Mix.install([{:wardrik_vault, "~> 0.1.0-rc.3"}])

keys = [WardrikVault.generate_key()]
store = WardrikStore.ETS.new(name: MyApp.Store)

children = [
  {WardrikStore, store},
  {WardrikVault, name: MyApp.Vault, store: store, keys: keys}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :rest_for_one)
```

- Persist the key outside your code to decrypt stored values after a restart.
- Make a key with `WardrikVault.generate_key/0`. Values are sealed with AES-256-GCM.
- The first key encrypts new values. Any configured key can decrypt values. To rotate, put a new key first.

## Use it

```elixir
jon = %WardrikCore.Principal{id: "user:jon"}

{:ok, vsn} =
  WardrikVault.put(MyApp.Vault, %WardrikVault.Secret{
    principal: jon,
    name: "github",
    value: "ghp_..."
  })

WardrikVault.fetch(MyApp.Vault, jon, "github")
# => {:ok, "ghp_..."}

WardrikVault.list(MyApp.Vault)
# => [{"user:jon", "github", :secret}]
```

Names are not encrypted. Anyone with store access can read secret names and their associated user IDs.

## Configure agent credentials

Set `ANTHROPIC_API_KEY` before starting IEx. Continue in the same session:

```elixir
children = [
  {WardrikCore.Backends.MemoryStore, name: :agents},
  {WardrikCore, backend: {WardrikCore.Backends.MemoryStore, name: :agents}}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :rest_for_one)

WardrikCore.start_agent(
  agent_id: "digest",
  model: "anthropic:claude-haiku-4-5",
  principal: jon,
  credentials: {WardrikVault, MyApp.Vault}
)
```

A tool reads only credentials associated with the agent's user.

## Your app's own secrets

Keep them under `WardrikVault.deployment/0`, and name them in options as `{:secret, name}`:

```elixir
{:ok, _vsn} =
  WardrikVault.put(MyApp.Vault, %WardrikVault.Secret{
    principal: WardrikVault.deployment(),
    name: "SLACK_SIGNING_SECRET",
    value: "example-signing-secret"
  })

WardrikVault.value(MyApp.Vault, {:secret, "SLACK_SIGNING_SECRET"})
# => {:ok, "example-signing-secret"}
```

No agent's tools can read them.

## OAuth tokens

Give the vault a `WardrikVault.Grants` module, such as [WardrikOAuth](https://hexdocs.pm/wardrik_oauth),
to refresh tokens and start sign-ins:

See [WardrikOAuth setup](https://hexdocs.pm/wardrik_oauth) for a complete supervision tree and resolver example.
