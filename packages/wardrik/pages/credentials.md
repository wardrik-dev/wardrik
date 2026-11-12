# Credentials and sign-ins

A tool that acts for a person needs their token. Wardrik keeps tokens sealed. An agent's tools
get only the tokens of the person it works for. When there's none, that person is asked to sign in.

## Setup

Nothing here calls a model. `"Iv1.your-client-id"` stands for your GitHub OAuth app.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.10"}])

# Allows everything. Your app's authorizer decides who may do what.
defmodule MyApp.AllowAll do
  @behaviour Wardrik.Authorizer
  def authorize(_request, _opts), do: :ok
end

# Every agent works for Maria.
defmodule MyApp.Agents do
  @behaviour Wardrik.Resolver
  def resolve(_request, _opts), do: {:ok, %Wardrik.Resolved{principal: Wardrik.principal("maria")}}
end

# Gives everyone the same GitHub app.
defmodule MyApp.OAuthApps do
  @behaviour Wardrik.OAuth.Resolver

  @impl true
  def provider(%{name: "github"}, _opts) do
    {:ok,
     Wardrik.OAuth.Provider.new("github",
       key: "github",
       authorization_endpoint: "https://github.com/login/oauth/authorize",
       token_endpoint: "https://github.com/login/oauth/access_token",
       client_id: "Iv1.your-client-id",
       client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
       scopes: ~w(repo)
     )}
  end

  def provider(_request, _opts), do: {:error, :not_found}
end

{:ok, _} =
  Wardrik.start_link(
    name: MyApp.AgentRuntime,
    authorizer: {MyApp.AllowAll, []},
    resolver: {MyApp.Agents, []},
    vault_keys: [Wardrik.Vault.generate_key()],
    oauth: [page: "https://agents.example.com/oauth", resolver: {MyApp.OAuthApps, []}]
  )
```

## Vault keys

`:vault_keys` seals every secret. Make one with `Wardrik.Vault.generate_key/0`, and keep it out of your
code:

```elixir
config :my_app, MyApp.AgentRuntime, vault_keys: [System.fetch_env!("WARDRIK_KEY")]
```

- The first key seals. Any key unseals.
- To rotate, put the new key first, and keep the old one until nothing needs it.

## Secrets

Wardrik's vault is `MyApp.AgentRuntime.Vault`. Seal a secret for a person, for one purpose:

```elixir
{:ok, _vsn} =
  Wardrik.Vault.put(
    MyApp.AgentRuntime.Vault,
    %Wardrik.Vault.Secret{principal: Wardrik.principal("maria"), name: "crm-key", value: "crm_..."},
    kind: :header
  )
```

- An agent's tools read only the secrets of the person it works for.
- A secret is read only for its kind. See `t:Wardrik.Vault.kind/0`.
- To keep secrets elsewhere, set `credentials: {MyApp.Tokens, opts}`, a `WardrikCore.Credentials`.

## API keys

Code asks the `:key_source`, a `WardrikCore.Keys`, for a key by name, such as `ZAI_API_KEY`:

```elixir
Wardrik.key_name("zai_coding_plan:glm-5.1")
#=> "ZAI_API_KEY"
```

Set `key_source: {MyApp.Keys, []}`. Without it, code finds its own, as ReqLLM reads the
environment.

## Secrets in config

An option that holds a secret takes `{:secret, name}`, a secret sealed for the deployment:

```elixir
{:ok, _vsn} =
  Wardrik.Vault.put(
    MyApp.AgentRuntime.Vault,
    %Wardrik.Vault.Secret{principal: Wardrik.Vault.deployment(), name: "HOOK_SECRET", value: "s3cret"}
  )
```

```elixir
config :my_app, MyApp.AgentRuntime,
  notify: [targets: [audit: {Wardrik.Notify.Webhook, url: url, secret: {:secret, "HOOK_SECRET"}}]],
  mcp: [
    linear: [
      transport:
        {:streamable_http, url: url, headers: %{"authorization" => {:secret, "LINEAR_TOKEN"}}}
    ]
  ]
```

- Channels and notify targets read theirs each time they're used.
- MCP servers read theirs as each connection starts. After changing one, call
  `Wardrik.MCP.reconnect/2`.
- A header takes the secret as sealed, as `"Bearer lin_api_..."`, or as
  `["Bearer ", {:secret, "LINEAR_TOKEN"}]`.
- A secret sealed nowhere is `nil`, and logged. An MCP server waits until it's sealed.

## Sign-ins

When a tool needs an account the person hasn't connected, its call waits on a sign-in.
`Wardrik.Agent.authorization/2` returns the link. Once the person signs in, every call waiting on
it carries on.

```elixir
# Connect an account before any agent asks
Wardrik.sign_in(MyApp.AgentRuntime, "github", Wardrik.principal("maria"))
#=> {:ok, %{url: "https://github.com/login/oauth/authorize?..."}}

Wardrik.signing_in?(MyApp.AgentRuntime, "github", Wardrik.principal("maria"))
#=> true
```

- A device sign-in also gives the `code` to enter at `url`.
- Each provider your resolver gives is named after the credential it grants, here `"github"`.
- The resolver runs at each sign-in and refresh, so a new client secret needs no restart.
- An account is the person's who signed in. Only the OAuth app that issued it renews it.
- When you delete an OAuth app, call `Wardrik.forget_client/2` with its key.

## Sign-in pages

Sign-ins come back to `page`. Mount the pages there, with a function that returns who is at the
browser:

```elixir
Wardrik.sign_in_pages(MyApp.AgentRuntime, {MyApp.Session, :principal, []})
#=> {Wardrik.OAuth.Plug, %{oauth: MyApp.AgentRuntime.OAuth, ...}}

# In a Phoenix router
forward "/oauth", Wardrik.OAuth.Plug,
  oauth: MyApp.AgentRuntime.OAuth,
  principal: {MyApp.Session, :principal, []}
```

A sign-in finishes only for the person who started it. See
`Wardrik.OAuth` for device sign-ins and renewal.
