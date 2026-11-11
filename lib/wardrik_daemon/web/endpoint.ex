defmodule WardrikDaemon.Web.Endpoint do
  @moduledoc """
  The Phoenix endpoint for the dashboard. `WardrikDaemon.HTTP` forwards every request under
  `/web` to it.

      {WardrikDaemon.Web.Endpoint,
       secret_key_base: key, daemon: daemon, server: false, live_view: [signing_salt: salt]}

  The pages read `:daemon`. It holds the Wardrik instance, the daemon's store, its orgs and its
  config.
  """

  use Phoenix.Endpoint, otp_app: :wardrik_daemon

  @session [
    store: :cookie,
    key: "_wardrik_web",
    signing_salt: "wardrik web session",
    encryption_salt: "wardrik web cookie",
    same_site: "Lax"
  ]

  socket("/web/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session], check_origin: :conn],
    longpoll: false
  )

  plug Plug.Session, @session
  plug WardrikDaemon.Web.Router
end
