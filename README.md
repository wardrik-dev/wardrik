# WardrikVault

Keeps credentials sealed at rest, for [WardrikCore](https://hexdocs.pm/wardrik_core) agents' tools
to call with.

## Install

```elixir
def deps do
  [
    {:wardrik_vault, "~> 0.1.0-rc.1"}
  ]
end
```

## Start a vault

The vault keeps credentials in a [WardrikStore](https://hexdocs.pm/wardrik_store). Start it after
the store:

```elixir
store = WardrikStore.ETS.new(name: MyApp.Store)

children = [
  {WardrikStore, store},
  {WardrikVault, name: MyApp.Vault, store: store, keys: [System.fetch_env!("VAULT_KEY")]}
]
```

Every function takes the vault's name. It raises if the vault isn't started.

Make a key with `WardrikVault.generate_key/0`. Values are sealed with AES-256-GCM.

* The first key seals. Any key unseals.
* To rotate, put a new key first. Keep the old one behind it until nothing needs it.
* Without a key, nothing is sealed or unsealed.

## Put credentials in

A credential belongs to a `WardrikCore.Principal`, by its `id`:

```elixir
jon = %WardrikCore.Principal{id: "user:jon"}

{:ok, vsn} =
  WardrikVault.put(MyApp.Vault, %WardrikVault.Secret{principal: jon, name: "github", value: "ghp_..."})

WardrikVault.fetch(MyApp.Vault, jon, "github")
#=> {:ok, "ghp_..."}

WardrikVault.lookup(MyApp.Vault, jon, "github")
#=> {:ok, :secret, "ghp_...", vsn}

WardrikVault.list(MyApp.Vault)
#=> [{"user:jon", "github", :secret}]
```

`list/1` and `names/2` need no key. The vault seals values, not names. Anyone who can read the
store can see who holds a credential of which name.

## Give it to agents

The vault is a `WardrikCore.Credentials`. Give an agent the vault's name:

```elixir
WardrikCore.start_agent(
  agent_id: "digest",
  model: "anthropic:claude-haiku-4-5",
  principal: jon,
  credentials: {WardrikVault, MyApp.Vault}
)
```

The agent's saved state holds only that name, never a key.

A tool reads only what its turn's principal holds. Nothing falls back from a person to their org.
Give an agent that works for your org a principal of its own.

## The deployment's own secrets

Secrets that belong to no agent owner are the deployment's. These are your app's keys, such as a
model provider's, and secrets your options would otherwise hold inline.

Keep them under `WardrikVault.deployment/0`. Name one in an option as `{:secret, name}`:

```elixir
{:ok, _vsn} =
  WardrikVault.put(MyApp.Vault, %WardrikVault.Secret{
    principal: WardrikVault.deployment(),
    name: "SLACK_SIGNING_SECRET",
    value: secret
  })

WardrikVault.value(MyApp.Vault, {:secret, "SLACK_SIGNING_SECRET"})
#=> {:ok, "8f14..."}

WardrikVault.value(MyApp.Vault, "8f14...")
#=> {:ok, "8f14..."}
```

`value/2` reads the secret on each call, so a new one takes effect at once. A plain value comes
back as it is. `read_value/3` does the same without a running vault.

No agent works for the deployment, so a tool's credentials never come from it.

## Grants

A grant is a credential someone gives by authorizing an account, like an OAuth token. Give the
vault a `WardrikVault.Grants` module to handle them:

```elixir
{WardrikVault, name: MyApp.Vault, store: store, keys: keys, grants: {MyApp.OAuth, opts}}
```

When a tool needs a credential, the vault calls the module with a `WardrikVault.Grants.Request`:

1. If the principal holds a grant, the vault calls the module's `renew/2`.
2. If nobody holds it, the vault calls `ask/2`. It returns `{:authorize, url}`, and the tool's call
   waits there.

The module writes what it gets back with `WardrikVault.put/3` and `kind: :grant`. Pass `if_vsn:` so
two renewals never write over each other.
