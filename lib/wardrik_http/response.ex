defmodule WardrikHTTP.Response do
  @moduledoc false

  import Plug.Conn

  alias Wardrik.Error

  @statuses %{
    invalid_request: 400,
    unauthorized: 401,
    forbidden: 403,
    not_found: 404,
    conflict: 409,
    internal: 500,
    not_supported: 501,
    unavailable: 503
  }

  @doc "Sends `operation`'s output with its success status, or the error."
  @spec answer(Plug.Conn.t(), WardrikProtocol.operation(), {:ok, term()} | {:error, Error.t()}) ::
          Plug.Conn.t()
  def answer(conn, %{status: status}, {:ok, nil}), do: send_resp(conn, status, "")
  def answer(conn, %{status: status}, {:ok, output}), do: json(conn, status, output)
  def answer(conn, _operation, {:error, %Error{} = error}), do: error(conn, error)

  @doc "Sends a channel's response unchanged, or the error."
  @spec relay(Plug.Conn.t(), {:ok, map()} | {:error, Error.t()}) :: Plug.Conn.t()
  def relay(conn, {:ok, %{"status" => status, "headers" => headers, "body" => body}}) do
    headers
    |> Enum.reduce(conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)
    |> send_resp(status, body)
  end

  def relay(conn, {:error, %Error{} = error}), do: error(conn, error)

  @doc "Sends `error` with the HTTP status for its type, as `404` for `:not_found`."
  @spec error(Plug.Conn.t(), Error.t()) :: Plug.Conn.t()
  def error(conn, %Error{type: type} = error),
    do: conn |> challenge(type) |> json(Map.fetch!(@statuses, type), Error.json(error))

  @doc "Sends `body` as JSON."
  @spec json(Plug.Conn.t(), pos_integer(), term()) :: Plug.Conn.t()
  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(body))
  end

  defp challenge(conn, :unauthorized), do: put_resp_header(conn, "www-authenticate", "Bearer")
  defp challenge(conn, _type), do: conn
end
