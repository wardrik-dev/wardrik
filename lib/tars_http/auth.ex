defmodule TarsHTTP.Auth do
  @moduledoc """
  Lets through a request that presents a `TarsHTTP.Token`, as
  `Authorization: Bearer tars_…`, and assigns the token as `:token`.

  Any other request is answered 401, with `WWW-Authenticate: Bearer`, and
  goes no further.
  """

  @behaviour Plug

  import Plug.Conn

  alias TarsHTTP.Resource
  alias TarsHTTP.Token

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with [header] <- get_req_header(conn, "authorization"),
         [scheme, secret] <- String.split(header, " ", parts: 2, trim: true),
         "bearer" <- String.downcase(scheme),
         {:ok, token} <- Token.verify(String.trim(secret)) do
      assign(conn, :token, token)
    else
      _unknown ->
        body = Resource.error("unauthorized", "Present a token as Authorization: Bearer tars_…")

        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="tars"))
        |> put_resp_content_type("application/json")
        |> send_resp(401, JSON.encode!(body))
        |> halt()
    end
  end
end
