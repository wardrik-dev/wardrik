# reach.check runs earlier in the same VM during precommit, and sets the logger back to debug.
Logger.configure(level: :warning)

{:ok, _server} = WardrikWeb.Test.Server.start()
{:ok, _servers} = WardrikWeb.Test.Servers.start()
{:ok, _connections} = WardrikWeb.Test.Connections.start()

{:ok, _endpoint} =
  WardrikWeb.Test.Endpoint.start_link(
    secret_key_base: String.duplicate("k", 64),
    live_view: [signing_salt: "test-live-salt"],
    server: false
  )

ExUnit.start()
