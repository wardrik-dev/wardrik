defmodule WardrikHTTP.Bearer do
  @moduledoc """
  Authenticates a request by its API token, sent as `Authorization: Bearer wrk_...`.

  Checks the token with the server's `c:Wardrik.Server.authenticate/2`. Returns an `:unauthorized`
  error if the header is missing.
  """

  @behaviour WardrikHTTP.Authenticator

  alias Wardrik.Error

  @impl WardrikHTTP.Authenticator
  def authenticate(%{conn: conn, server: server, wardrik: wardrik}, _opts) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> secret] -> server.authenticate(wardrik, secret)
      _none -> {:error, Error.new(:unauthorized, "Send an API token as Authorization: Bearer.")}
    end
  end
end
