defmodule Wardrik.HTTP.BodyReader do
  @moduledoc """
  Keeps a request's raw body while `Plug.Parsers` reads it, for webhook signatures.

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: JSON,
        body_reader: {Wardrik.HTTP.BodyReader, :read_body, []}
  """

  import Plug.Conn

  @doc "Reads the body as `Plug.Conn.read_body/2` does, and keeps a copy."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, get_kept_body(conn, body)}
      {:more, body, conn} -> {:more, body, get_kept_body(conn, body)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the kept raw body, or `nil` if none was kept."
  @spec get_kept_body(Plug.Conn.t()) :: binary() | nil
  def get_kept_body(conn), do: conn.private[:wardrik_http_body]

  defp get_kept_body(conn, body),
    do: put_private(conn, :wardrik_http_body, (get_kept_body(conn) || "") <> body)
end
