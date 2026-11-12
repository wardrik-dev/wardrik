# Wardrik.OAuth

OAuth sign-in for [WardrikCore](https://hexdocs.pm/wardrik_core) agents. Tokens are sealed in a
`Wardrik.Vault`. [Wardrik](https://hexdocs.pm/wardrik) sets this
up for you; see [Credentials and sign-ins](https://hexdocs.pm/wardrik/credentials.html).

## Start OAuth

Set `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET` for your Google OAuth app before starting IEx.
Register `https://agents.example.com/oauth/callback` as its redirect URI.
Use your app's public address instead of `agents.example.com`.

```elixir
Mix.install([{:wardrik, "~> 0.1.0-rc.10"}])

defmodule MyApp.OAuthApps do
  @behaviour Wardrik.OAuth.Resolver

  @impl true
  def provider(%{name: "google"}, _opts) do
    {:ok,
     Wardrik.OAuth.Provider.new("google",
       key: "google",
       issuer: "https://accounts.google.com",
       client_id: System.fetch_env!("GOOGLE_CLIENT_ID"),
       client_secret: System.fetch_env!("GOOGLE_CLIENT_SECRET"),
       scopes: ~w(openid email https://www.googleapis.com/auth/calendar.readonly),
       authorization_params: %{access_type: "offline", prompt: "consent"}
     )}
  end

  def provider(_request, _opts), do: {:error, :not_found}
end

store = Wardrik.Store.ETS.new(name: MyApp.Store)
keys = [Wardrik.Vault.generate_key()]

children = [
  {Wardrik.Store, store},
  {Wardrik.Vault,
   name: MyApp.Vault, store: store, keys: keys, grants: {Wardrik.OAuth, MyApp.OAuth}},
  {Wardrik.OAuth,
   name: MyApp.OAuth,
   vault: MyApp.Vault,
   store: store,
   page: "https://agents.example.com/oauth",
   resolver: {MyApp.OAuthApps, []}}
]

{:ok, _supervisor} = Supervisor.start_link(children, strategy: :rest_for_one)
```

- This example stores data in memory. Persist the vault key and use persistent storage in your app.
- The resolver is called for sign-ins and token refreshes.
- See `Wardrik.OAuth.Provider` and `Wardrik.OAuth.start_link/1` for options.

## Mount the pages

Phoenix router fragment: implement `MyApp.Session.principal/1` to return the signed-in user.

```elixir
forward("/oauth", Wardrik.OAuth.Plug,
  oauth: MyApp.OAuth,
  principal: {MyApp.Session, :principal, []}
)
```

- `/callback` finishes a browser sign-in. Register it as each OAuth app's redirect URI.
- `/device/:id` shows a device sign-in's code.
- `/client` serves Wardrik's own client ID document.
- `:principal` returns who is signed in to your app at the browser. Only they can finish their
  sign-in.

## Configure agent credentials

In an existing Core runtime, pass the vault through `credentials: {Wardrik.Vault, MyApp.Vault}`.
Configure the MCP server with `credential_name: "google"` to use the provider above.
See `Wardrik.MCP` for server setup.

- A missing credential parks the tool call with a `WardrikCore.Authorization` containing a sign-in URL.
- Your app displays that URL and resumes matching parked calls after sign-in.
- Set `:on_granted` to a callback receiving the provider name and user, followed by your configured arguments.
- A sign-in expires after 15 minutes. Repeating an active sign-in returns the same URL.
- Refresh uses the OAuth app that issued the token. A failed refresh requires another sign-in.

[Wardrik](https://hexdocs.pm/wardrik) configures the resume callback automatically.
See [Credentials and sign-ins](https://hexdocs.pm/wardrik/credentials.html).
