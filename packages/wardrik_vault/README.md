# wardrik_vault

Credentials for [Wardrik](../wardrik) agents, sealed with a key you hold.

A tool names the secret it needs rather than holding one, and is handed it
resolved for the call it is answering:

```elixir
@impl true
def annotations(_name), do: %{credentials: ["github"]}

def run(%{url: url}, %Wardrik.Tool.Context{credentials: %{"github" => credential}}),
  do: fetch(url, Wardrik.Credential.reveal(credential))
```

The vault is the resolver that answers. It seals each credential with
AES-256-GCM into Wardrik's store, so there is no separate service to run and
nothing kept in plaintext, and finds a name for each call the most specific
first: the call's user's, then its org's, then the deployment's.

```elixir
def deps do
  [{:wardrik_vault, "~> 0.1.0"}]
end
```

```elixir
# config/runtime.exs
config :wardrik_vault, WardrikVault, keys: [System.fetch_env!("WARDRIK_VAULT_KEY")]
```

```elixir
Wardrik.Fleet.spawn(id, config: config, credentials: WardrikVault)

WardrikVault.put("github", {"acme", "jon"}, "ghp_xxx")   # jon's, in acme
WardrikVault.put("pagerduty", "acme", "pd_xxx")         # acme's
WardrikVault.put("linear", nil, "lin_xxx")              # the deployment's
```

A credential nobody holds yet can be asked for instead, by naming a grants
module; [wardrik_oauth](../wardrik_oauth) is one:

```elixir
config :wardrik_vault, WardrikVault, keys: [...], grants: WardrikOAuth
```
