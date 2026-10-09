defmodule WardrikHTTP.Auth do
  @moduledoc """
  Lets through a request its `WardrikHTTP.Authenticator` knows, the listener's
  `:authenticator` or `WardrikHTTP.Token`, and assigns its
  `WardrikHTTP.Caller` as `:caller`.

  A request from no caller the authenticator knows is answered 401, with the
  authenticator's challenge as `WWW-Authenticate`, and one whose credential
  could not be checked is answered 503. Neither goes further.
  """

  @behaviour Plug

  import Plug.Conn

  alias WardrikHTTP.Resource

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    {module, opts} = authenticator(conn.assigns.options[:authenticator])

    case module.authenticate(conn, opts) do
      {:ok, caller} ->
        assign(conn, :caller, caller)

      {:error, :unavailable} ->
        body = Resource.error("unavailable", "Credentials cannot be checked now. Try again.")
        refuse(conn, 503, body)

      {:error, :unauthorized} ->
        body = Resource.error("unauthorized", "No credential this server knows was presented.")

        conn
        |> put_resp_header("www-authenticate", module.challenge(opts))
        |> refuse(401, body)
    end
  end

  defp authenticator(nil), do: {WardrikHTTP.Token, []}
  defp authenticator({module, opts}), do: {module, opts}
  defp authenticator(module) when is_atom(module), do: {module, []}

  defp refuse(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
    |> halt()
  end
end
