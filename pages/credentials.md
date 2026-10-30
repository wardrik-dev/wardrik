# Credentials and sign-ins

A tool that acts as a person needs their token. Wardrik keeps credentials sealed, and gives each
agent's tools only the credentials its principal holds. When there's none yet, it sends the person
to sign in.

## Keep credentials

Give Wardrik keys to seal credentials with:

```elixir
config :my_app, MyApp.Wardrik, keys: [System.fetch_env!("WARDRIK_KEY")]
```

Make a key with `WardrikVault.generate_key/0`. The first key seals, and any key unseals. To rotate,
put the new key first and keep the old one after it until nothing needs it.

Keep a secret for an org or a person:

```elixir
:ok = MyApp.Wardrik.put_secret("acme/@maria", "github", "ghp_...")
{:ok, "ghp_..."} = MyApp.Wardrik.fetch_secret("acme/@maria", "github")
["github"] = MyApp.Wardrik.list_secrets("acme/@maria")
:ok = MyApp.Wardrik.delete_secret("acme/@maria", "github")
```

Every agent reads its principal's credentials, and nothing else. Putting and deleting a secret is
recorded in the audit.

`lookup_secret/2` also returns the secret's kind and version. The kind is `:secret`, or `:grant` for
an account someone connected. Pass the version as `put_secret/4`'s `if_vsn:` to write over only the
version you read.

## Keep API keys

An API key is what installed code calls a service with, like a model provider's `ZAI_API_KEY` or
web search's `BRAVE_API_KEY`. Seal it as a deployment secret, and every agent's code reads it:

```elixir
:ok = MyApp.Wardrik.put_secret("deployment", "ZAI_API_KEY", "...")
```

An org or a person brings their own by sealing a key of the same name. A person's agent reads the
person's key first, then the org's, then the deployment's. Each model call reads its provider's key
as it's made, so a new key takes effect at once. Where none is sealed, the code finds its own, as
ReqLLM reads the environment. See `WardrikCore.Keys`.

Keys never reach a tool's credentials, and the deployment's keys never reach an owner: a server an
org adds can't name `ZAI_API_KEY` and be sent the deployment's.

## Secrets in config

An option that holds a secret takes `{:secret, name}` instead, naming a deployment secret. Your
config then holds none:

```elixir
config :my_app, MyApp.Wardrik,
  channels: [slack: {WardrikSlack, signing_secret: {:secret, "SLACK_SIGNING_SECRET"}, ...}],
  notify: [targets: [audit: {Wardrik.Notify.Webhook, url: url, secret: {:secret, "HOOK_SECRET"}}]],
  oauth: [providers: [github: [client_id: id, client_secret: {:secret, "GITHUB_CLIENT_SECRET"}]]]
```

  * A channel's and a notify target's secrets are read each time they're used.
  * An OAuth provider's are read at each sign-in.
  * A channel's processes, like Slack's Socket Mode, read theirs when they start. Restart Wardrik
    after changing those.

A secret sealed nowhere is `nil`, and logged.

## Let people sign in

Give Wardrik one OAuth app per service, each named after the credential it grants:

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
`Wardrik.Agent.authorization/4` returns the link. Once the person signs in, the token is sealed and
every call waiting on it carries on. They sign in once.

## Connect ahead of time

A person or an org can connect an account before any agent asks:

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

`disconnect` returns `connected: true` when there was an account to forget. Forgetting one is
recorded in the audit.

An account belongs to its owner. A person's agents reach the person's accounts, and an org's agents
reach the org's. Nothing falls back from one to the other.

A server the owner added, whose agents sign in in a browser, is one of their accounts too, by the
server's name. The owner can sign in to it, or out, before any agent calls it. Adding the server
asks the owner to sign in, whoever adds it: an org's admin signs the org in.

## Mount the sign-in pages

A sign-in comes back to your app, so mount its pages at `page`. In a Phoenix router:

```elixir
forward "/oauth", WardrikOAuth.Plug, oauth: MyApp.Wardrik.OAuth
```

`Wardrik.sign_in_pages/1` returns the plug and its options. See
[WardrikOAuth](https://hexdocs.pm/wardrik_oauth) for every provider option, device sign-ins and
renewal.
