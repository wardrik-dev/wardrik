defmodule WardrikOAuth.Plug do
  @moduledoc """
  The pages a browser comes back to from a sign-in, for an app that serves
  none of Wardrik's HTTP API. Forward the redirect URL's path to it:

      # lib/my_app_web/router.ex
      forward "/oauth", WardrikOAuth.Plug, agents: MyApp.Agents

      # config/runtime.exs
      config :my_app, MyApp.Agents,
        store: [repo: MyApp.Repo],
        vault: [keys: [System.fetch_env!("WARDRIK_VAULT_KEY")]],
        plugins: [
          {WardrikOAuth,
           redirect: [url: "https://myapp.example.com/oauth"],
           providers: [
             github: [
               resource: "https://api.githubcopilot.com/mcp/",
               issuer: "https://github.com/login/oauth",
               client_id: System.fetch_env!("GITHUB_CLIENT_ID"),
               client_secret: System.fetch_env!("GITHUB_CLIENT_SECRET"),
               scopes: ~w(repo)
             ]
           ]}
        ]

  Notice the forward's path is the redirect URL's. A sign-in comes back as a
  GET, so it reads no body, and a router's `forward` serves it. An app that
  mounts `WardrikHTTP.Plug` needs none of this: it serves the same pages,
  under a redirect URL beneath its `at`.
  """

  @behaviour Plug

  alias WardrikOAuth.Callback.Page

  @impl Plug
  def init(opts), do: opts |> Keyword.validate!([:agents]) |> Keyword.fetch!(:agents)

  @impl Plug
  def call(conn, agents) do
    case Wardrik.Host.settings(Wardrik.Instance.host(agents), WardrikOAuth) do
      [oauth: oauth] ->
        Page.call(conn, Page.init(oauth: oauth))

      [] ->
        raise ArgumentError,
              "#{inspect(agents)} has no sign-ins to come back to: add WardrikOAuth to its plugins"
    end
  end
end
