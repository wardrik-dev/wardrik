# Credentials and sign-ins

A tool that acts as a person needs their token. Wardrik keeps credentials sealed, gives each
agent's tools the ones its principal holds, and sends a person to sign in when there's none yet.

## Keep credentials

Give Wardrik keys to seal credentials with:

```elixir
Wardrik.new(
  name: MyApp.Wardrik,
  data_dir: "/var/lib/my_app",
  keys: [System.fetch_env!("WARDRIK_KEY")]
)
```

Make a key with `WardrikVault.generate_key/0`. The first key seals, and any of them unseals. To
rotate, put a new key first, and keep the old one behind it until nothing needs it.

Every agent then reads its principal's credentials, and nothing else. Put a secret in for someone:

```elixir
maria = %WardrikCore.Principal{id: "acme/@maria"}

WardrikVault.put(Wardrik.vault(wardrik), maria, "github", "ghp_...")
```

## Let people sign in

Give Wardrik your OAuth apps, one per service, named like the credential each grants:

```elixir
Wardrik.new(
  name: MyApp.Wardrik,
  data_dir: "/var/lib/my_app",
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
)
```

When a tool needs a credential its principal hasn't granted, its call waits on a sign-in.
`Wardrik.Agent.authorization/4` gives the link. Once the person has signed in, the token is sealed,
and every call waiting on it carries on. They only sign in once.

## Connect ahead of time

A person, or an org, connects an account before any agent asks:

```elixir
{:ok, [%Wardrik.Connection{provider: "github", connected: false}]} =
  Wardrik.Connections.list(scope, owner: "acme/@jon")

{:ok, %Wardrik.Connecting{authorization: %Wardrik.Authorization{url: url}}} =
  Wardrik.Connections.connect(scope, "github", owner: "acme/@jon")

{:ok, %Wardrik.Connection{}} = Wardrik.Connections.disconnect(scope, "github", owner: "acme/@jon")
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
