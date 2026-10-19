# The vault

Credentials for Wardrik agents, sealed with a key you hold.

A tool names the secret it needs rather than holding one, and is handed it
resolved for the call it is answering:

```elixir
@impl true
def annotations(_name), do: %{credentials: ["github"]}

def run(%{url: url}, %Wardrik.Tool.Context{credentials: %{"github" => credential}}),
  do: fetch(url, Wardrik.Credential.reveal(credential))
```

The vault is the host's `Wardrik.Credentials` that answers. It seals each credential with
AES-256-GCM into Wardrik's store, so there is no separate service to run and
nothing kept in plaintext, and finds a name for each call the most specific
first: the call's user's, then its org's, then the deployment's.

```elixir
# lib/my_app/application.ex
vault = WardrikVault.new(store: store, keys: [System.fetch_env!("WARDRIK_VAULT_KEY")])
host = Wardrik.Host.new(store: store, credentials: vault)
children = [{WardrikStore, store}, {Wardrik.Core, host: host}]
```

```elixir
alias Wardrik.Resource

WardrikVault.put(vault, "github", Resource.parse!("acme/@jon"), value: "ghp_xxx")   # jon's, in acme
WardrikVault.put(vault, "pagerduty", Resource.parse!("acme"), value: "pd_xxx")     # acme's
WardrikVault.put(vault, "linear", Resource.deployment(), value: "lin_xxx")         # the deployment's
```

A credential nobody holds yet can be asked for instead, by giving the vault
`WardrikVault.Grants`; [wardrik_oauth](../../wardrik_oauth)'s are one:

```elixir
WardrikVault.new(store: store, keys: keys, grants: oauth)
```

An agent reads only what its owner holds: its user's, or its org's. A
deployment shares a credential with every agent by naming it, its own sealed
secret of that name or, where it holds none, the environment variable:

```elixir
WardrikVault.new(store: store, keys: keys, shared: ["SEARCH_API_KEY"])
```
