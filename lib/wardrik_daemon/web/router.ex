defmodule WardrikDaemon.Web.Router do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import WardrikWeb.Router

  pipeline :browser do
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/web" do
    pipe_through(:browser)

    get("/sign-in", WardrikDaemon.Web.SignIn, :show)
    get("/sign-out", WardrikDaemon.Web.SignIn, :out)

    wardrik_dashboard("/",
      resolver: {WardrikDaemon.Web.Resolver, []},
      extensions: [WardrikDaemon.Web.Pages],
      settings: [
        servers:
          {WardrikDaemon.Web.Settings,
           store: WardrikDaemon.Servers,
           kind: :mcp_server,
           actions: {"mcp_server.read", "mcp_server.add", "mcp_server.delete"},
           schema: "server_input",
           columns: [{"URL", "url"}, {"Authentication", "auth"}],
           common: ~w(name url auth tools)},
        secrets: {WardrikDaemon.Web.SecretSettings, []},
        notify_targets:
          {WardrikDaemon.Web.Settings,
           store: WardrikDaemon.NotifyTargets,
           kind: :notify_target,
           actions: {"notify_target.read", "notify_target.add", "notify_target.delete"},
           schema: "notify_target_input",
           columns: [{"URL", "url"}, {"Signing secret", "secret"}],
           common: ~w(name url secret)},
        oauth_apps:
          {WardrikDaemon.Web.Settings,
           store: WardrikDaemon.OAuthApps,
           kind: :provider,
           actions: {"provider.read", "provider.add", "provider.delete"},
           schema: "provider_input",
           columns: [
             {"Issuer", "issuer"},
             {"Client ID", "client_id"},
             {"Sign-in", "flow"},
             {"Scopes", "scopes"}
           ],
           common: ~w(name issuer client_id client_secret scopes)},
        connections: {WardrikDaemon.Web.ConnectionSettings, []}
      ],
      socket_path: "/web/live",
      sign_in: "/web/sign-in"
    )
  end
end
