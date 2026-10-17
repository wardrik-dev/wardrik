defmodule WardrikHTTP.Auth do
  @moduledoc """
  Lets through a request the listener's `WardrikHTTP.Authenticator` knows, and
  assigns its `WardrikHTTP.Caller` as `:caller`.

  A request from no caller the authenticator knows is answered 401, with the
  authenticator's challenge as `WWW-Authenticate`, and one whose credential
  could not be checked is answered 503. Neither goes further.

  A request to `/v1/hooks/`, from outside to one of an agent's triggers,
  presents no credential and is let through: the trigger checks its
  signature, and `WardrikHTTP.Router` gives it no caller but that trigger.
  So is one to `/v1/channels/`, which a chat channel's medium sends, and
  the channel checks.
  """

  @behaviour Plug

  import Plug.Conn

  alias Wardrik.Resource
  alias WardrikHTTP.Authenticator

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["v1", "hooks" | _rest]} = conn, _opts), do: conn
  def call(%Plug.Conn{path_info: ["v1", "channels" | _rest]} = conn, _opts), do: conn

  def call(conn, _opts) do
    authenticator = Keyword.fetch!(conn.assigns.options, :authenticator)

    case Authenticator.authenticate(authenticator, conn) do
      {:ok, caller} ->
        assign(conn, :caller, caller)

      {:error, :unavailable} ->
        body = Resource.error("unavailable", "Credentials cannot be checked now. Try again.")
        refuse(conn, 503, body)

      {:error, :unauthorized} ->
        body = Resource.error("unauthorized", "No credential this server knows was presented.")

        conn
        |> put_resp_header("www-authenticate", Authenticator.challenge(authenticator))
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
