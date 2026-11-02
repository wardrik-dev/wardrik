# Credentials and sign-ins

A tool that acts as a person needs their token. Wardrik keeps credentials sealed, and gives each
agent's tools only the credentials its principal holds. When there's none yet, it sends the person
to sign in.

## Setup

In a fresh IEx session, start Wardrik with a key to seal credentials with, and an OAuth app for
GitHub:

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.2"}])

# Allows everything. Your app's authorizer decides who may do what.
defmodule MyApp.AllowAll do
  @behaviour Wardrik.Authorizer

  @impl true
  def authorize(_request, _opts), do: :ok
end

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    keys: [WardrikVault.generate_key()],
    oauth: [
      page: "https://agents.example.com/oauth",
      providers: [
        github: [
          authorization_endpoint: "https://github.com/login/oauth/authorize",
          token_endpoint: "https://github.com/login/oauth/access_token",
          client_id: "Iv1.your-client-id",
          client_secret: {:secret, "GITHUB_CLIENT_SECRET"},
          scopes: ~w(repo)
        ]
      ]
    ]
  )

scope = Wardrik.as(MyApp.AgentRuntime, "acme/@maria")
```

`"Iv1.your-client-id"` stands for your GitHub OAuth app's client ID. Nothing on this page calls a
model.

## Keep credentials

`:keys` seals every credential. Make a key with `WardrikVault.generate_key/0`, and keep it outside
your code:

```elixir
config :my_app, MyApp.AgentRuntime, keys: [System.fetch_env!("WARDRIK_KEY")]
```

The first key seals, and any key unseals. To rotate, put the new key first and keep the old one
after it until nothing needs it.

Wardrik keeps them in its vault, `MyApp.AgentRuntime.Vault`, a `WardrikVault`. Your app seals a
secret there for an org, as `"acme"`, a person, as `"acme/@maria"`, or the deployment, each for
one purpose:

```elixir
{:ok, _vsn} =
  WardrikVault.put(
    MyApp.AgentRuntime.Vault,
    %WardrikVault.Secret{
      principal: Wardrik.principal("acme/@maria"),
      name: "crm-key",
      value: "crm_live_..."
    },
    kind: :header
  )
```

  * Every agent's tools read its principal's credentials, and nothing else.
  * A secret is read only for its kind, so a header is never read as an API key. See
    `t:WardrikVault.kind/0`.
  * `wardrik_daemon` serves an owner's secrets over HTTP, and keeps them for you.

## Keep API keys

An API key is what installed code calls a service with, like a model provider's `ZAI_API_KEY` or
web search's `BRAVE_API_KEY`. Code asks the `:key_source`, a `WardrikCore.Keys`, for the key by
name, as `Wardrik.key_name/1` gives it:

```elixir
Wardrik.start_link(
  name: MyApp.AgentRuntime,
  authorizer: {MyApp.Authorizer, []},
  keys: [key],
  key_source: {MyApp.Keys, []}
)
```

Without one, the code finds its own, as ReqLLM reads its config and the environment.
`WardrikDaemon.Keys` is one that reads an agent's owner's keys from the vault, then its org's. To
give tools credentials from elsewhere, give `credentials: {MyApp.Tokens, opts}`, a
`WardrikCore.Credentials`.

## Secrets in config

An option that holds a secret takes `{:secret, name}` instead, naming a deployment secret. The
setup's GitHub app does, so seal its client secret:

```elixir
{:ok, _vsn} =
  WardrikVault.put(
    MyApp.AgentRuntime.Vault,
    %WardrikVault.Secret{
      principal: WardrikVault.deployment(),
      name: "GITHUB_CLIENT_SECRET",
      value: "your-client-secret"
    },
    kind: :client_secret
  )
```

Your config then holds none:

```elixir
config :my_app, MyApp.AgentRuntime,
  channels: [slack: {WardrikSlack, signing_secret: {:secret, "SLACK_SIGNING_SECRET"}, ...}],
  notify: [targets: [audit: {Wardrik.Notify.Webhook, url: url, secret: {:secret, "HOOK_SECRET"}}]],
  mcp: [
    linear: [
      transport:
        {:streamable_http, url: url, headers: %{"authorization" => {:secret, "LINEAR_TOKEN"}}}
    ]
  ],
  oauth: [providers: [github: [client_id: id, client_secret: {:secret, "GITHUB_CLIENT_SECRET"}]]]
```

  * A channel's and a notify target's secrets are read each time they're used. A webhook an org
    or person adds with `notify_targets.add` names a secret it holds, read from its vault.
  * An OAuth provider's are read at each sign-in.
  * An MCP server's are read as each connection starts. After sealing or removing one, connect
    the servers that name it again with
    `WardrikMCP.reconnect(MyApp.AgentRuntime.MCP, owner: owner, secret: name)`;
    `wardrik_daemon` does.
  * A channel's processes, like Slack's Socket Mode, read theirs when they start. Restart Wardrik
    after changing those.

A header takes the secret as sealed, so seal Linear's token with its scheme, as `:header`, the
same way: `value: "Bearer lin_api_..."`.

Or give the scheme in the header, as `["Bearer ", {:secret, "LINEAR_TOKEN"}]`.

An MCP server whose secret is sealed nowhere is down until it is. Any other secret sealed nowhere
is `nil`, and logged.

## Let people sign in

Each provider in `:oauth` is named after the credential it grants. The setup's `github` grants
`"github"`.

When a tool needs a credential its principal hasn't granted, its call waits on a sign-in.
`Wardrik.Agent.authorization/2` returns the link. Once the person signs in, the token is sealed and
every call waiting on it carries on. They sign in once.

## Add OAuth apps as it runs

An org or person adds an OAuth app for their people, its client secret named by reference. Seal
`GOOGLE_CLIENT_SECRET` for `"acme"` first, as `:client_secret`, then:

```elixir
Wardrik.Providers.add(scope,
  owner: "acme",
  name: "google",
  issuer: "https://accounts.google.com",
  client_id: "868288504182-example.apps.googleusercontent.com",
  client_secret: %{name: "GOOGLE_CLIENT_SECRET"},
  scopes: ["https://www.googleapis.com/auth/adwords"],
  authorization_params: %{access_type: "offline"}
)
#=> {:ok, %Wardrik.Provider{owner: "acme", name: "google", source: :runtime, ...}}
```

A person signs in with the nearest app of a name: their own, their org's, then the deployment's.
`Wardrik.Providers.list/2` lists them in that order, and `remove/3` removes the owner's own. The
client secret is read each time it's needed, and never answered.

## Connect ahead of time

A person or an org can connect an account before any agent asks:

```elixir
Wardrik.Connections.list(scope, owner: "acme/@maria")
#=> {:ok, [%Wardrik.Connection{provider: "github", connected: false}]}

Wardrik.Connections.connect(scope, "github", owner: "acme/@maria")
#=> {:ok,
#=>  %Wardrik.Connecting{
#=>    provider: "github",
#=>    connected: false,
#=>    authorization: %Wardrik.Authorization{url: "https://github.com/login/oauth/authorize?...", code: nil}
#=>  }}
```

Open the URL to sign in. Once the person has, `disconnect/3` forgets the account:

```elixir
Wardrik.Connections.disconnect(scope, "github", owner: "acme/@maria")
#=> {:ok, %Wardrik.Connection{provider: "github", connected: false}}
```

`disconnect` returns `connected: true` when there was an account to forget. Forgetting one is
recorded in the audit.

An account belongs to its owner. A person's agents reach the person's accounts, and an org's agents
reach the org's. Nothing falls back from one to the other. The apps they connect with do: a person
is offered their own, their org's and the deployment's.

A server the owner added, whose agents sign in in a browser, is one of their accounts too, by the
server's name. The owner can sign in to it, or out, before any agent calls it. Adding the server
asks the owner to sign in, whoever adds it: an org's admin signs the org in.

## Mount the sign-in pages

A sign-in comes back to your app, so mount its pages at `page`:

```elixir
Wardrik.sign_in_pages(MyApp.AgentRuntime)
#=> {WardrikOAuth.Plug, MyApp.AgentRuntime.OAuth}
```

In a Phoenix router:

```elixir
forward "/oauth", WardrikOAuth.Plug, oauth: MyApp.AgentRuntime.OAuth
```

See [WardrikOAuth](https://hexdocs.pm/wardrik_oauth) for every provider option, device sign-ins and
renewal.
