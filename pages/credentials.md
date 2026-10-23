# Credentials and sign-ins

A tool that acts as a person needs their token. Wardrik keeps credentials sealed, gives each
agent's tools the ones its principal holds, and sends a person to sign in when there's none yet.

## Keep credentials

Give Wardrik keys to seal credentials with:

```elixir
config :my_app, MyApp.Wardrik, keys: [System.fetch_env!("WARDRIK_KEY")]
```

Make a key with `WardrikVault.generate_key/0`. The first key seals, and any of them unseals. To
rotate, put a new key first, and keep the old one behind it until nothing needs it.

Every agent then reads its principal's credentials, and nothing else. Keep a secret for an org or a
person:

```elixir
:ok = MyApp.Wardrik.put_secret("acme/@maria", "github", "ghp_...")
{:ok, "ghp_..."} = MyApp.Wardrik.fetch_secret("acme/@maria", "github")
["github"] = MyApp.Wardrik.list_secrets("acme/@maria")
:ok = MyApp.Wardrik.delete_secret("acme/@maria", "github")
```

`lookup_secret/2` adds its kind, `:secret`, or `:grant` for an account someone connected, and its
version, for `put_secret/4`'s `if_vsn:`. Keeping and removing one is recorded in the audit.

## Let people sign in

Give Wardrik your OAuth apps, one per service, named like the credential each grants:

```elixir
config :my_app, MyApp.Wardrik,
  keys: [System.fetch_env!("WARDRIK_KEY")],
  oauth: [
    page: "https://agents.example.com/oauth",
    providers: [
      github: [
        issuer: "https://github.com/login/oauth",
        client_id: System.fetch_env!("GITHUB_CLIENT_ID"),
        client_secret: System.fetch_env!("GITHUB_CLIENT_SECRET"),
        scopes: ~w(repo)
      ]
    ]
  ]
```

When a tool needs a credential its principal hasn't granted, its call waits on a sign-in.
`Wardrik.Agent.authorization/4` gives the link. Once the person has signed in, the token is sealed,
and every call waiting on it carries on. They only sign in once.

## Connect ahead of time

A person, or an org, connects an account before any agent asks:

```elixir
Wardrik.Connections.list(scope, owner: "acme/@jon")
#=> {:ok, [%Wardrik.Connection{provider: "github", connected: false}]}

Wardrik.Connections.connect(scope, "github", owner: "acme/@jon")
#=> {:ok,
#=>  %Wardrik.Connecting{
#=>    provider: "github",
#=>    connected: false,
#=>    authorization: %Wardrik.Authorization{url: "https://github.com/login/oauth/authorize?...", code: nil}
#=>  }}

Wardrik.Connections.disconnect(scope, "github", owner: "acme/@jon")
#=> {:ok, %Wardrik.Connection{provider: "github", connected: true}}
```

An account is the owner's own: a person's agents reach their person's, and an org's agents reach
the org's. Nothing falls back from one to the other. Forgetting one is recorded in the audit.

## Mount the sign-in pages

A sign-in comes back to your app, so mount its pages at `page`. In a Phoenix router:

```elixir
forward "/oauth", WardrikOAuth.Plug, oauth: MyApp.Wardrik.OAuth
```

See [WardrikOAuth](https://hexdocs.pm/wardrik_oauth) for every provider option, device sign-ins,
and renewing.
