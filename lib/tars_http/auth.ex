defmodule TarsHTTP.Auth do
  @moduledoc """
  Lets through a request that presents a `TarsHTTP.Token`, as
  `Authorization: Bearer tars_…`, and assigns the token as `:token`.

  A request with no token the API knows is answered 401, with
  `WWW-Authenticate: Bearer`, and one whose token could not be read, the
  store having no quorum, is answered 503. Neither goes further.
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
      {:error, :unavailable} ->
        body = Resource.error("unavailable", "Tokens cannot be checked now. Try again.")
        refuse(conn, 503, body)

      _unknown ->
        body = Resource.error("unauthorized", "Present a token as Authorization: Bearer tars_…")

        conn
        |> put_resp_header("www-authenticate", ~s(Bearer realm="tars"))
        |> refuse(401, body)
    end
  end

  defp refuse(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
    |> halt()
  end
end
