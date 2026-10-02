# wardrik_oauth

Accounts a user connects to [Wardrik](../wardrik) by authorizing. When a tool
needs a credential the user has not connected, the turn waits, the user
authorizes, and the call goes ahead by itself with the token, which is kept
in [wardrik_vault](../wardrik_vault) and renewed without asking again.

```elixir
def deps do
  [{:wardrik_oauth, "~> 0.1.0"}]
end
```

```elixir
# config/runtime.exs
config :wardrik_vault, WardrikVault, keys: [System.fetch_env!("WARDRIK_VAULT_KEY")], grants: WardrikOAuth

config :wardrik_oauth, WardrikOAuth,
  client: [name: "Wardrik", document_url: "https://wardrik.dev/oauth/client"],
  providers: [
    github: [
      resource: "https://api.githubcopilot.com/mcp/",
      issuer: "https://github.com/login/oauth",
      client_id: System.get_env("GITHUB_CLIENT_ID"),
      client_secret: System.get_env("GITHUB_CLIENT_SECRET"),
      scopes: ~w(repo),
      flow: :auto
    ]
  ]
```

It finds the authorization server from the resource, and presents whichever
client identity the server accepts: one registered by hand, its own metadata
document, or a dynamic registration. A user authorizes one of two ways:

- **in a browser**, with an authorization code and PKCE: a link that comes
  back to your redirect URI, or the daemon's own loopback.
- **on another device**, with the device authorization grant (RFC 8628), where
  the server offers it: a code to enter on the server's page from a phone or
  any browser. Nothing has to reach back to the daemon, so one on a server
  with no browser and no open port can be authorized from Slack.

`flow: :auto`, the default, uses another device where the server offers it and
there is no browser to send the user through, and a browser otherwise.

A grant acts as whoever connected it, so only their calls find it: a user
whose org connected an account is still asked for their own.
