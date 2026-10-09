defmodule WardrikOAuth.Callback.Page do
  @moduledoc """
  The pages `WardrikOAuth.Callback` serves, under the redirect URL's path: a
  callback for each provider configured, `check`, and a 404 for anything
  else. What is shown is HTML-escaped, and every page is kept from caches,
  referrers and frames, and loads nothing.
  """

  @behaviour Plug

  import Plug.Conn

  alias WardrikOAuth.Callback

  @headers [
    {"cache-control", "no-store"},
    {"referrer-policy", "no-referrer"},
    {"content-security-policy", "default-src 'none'; style-src 'unsafe-inline'"},
    {"x-content-type-options", "nosniff"},
    {"x-frame-options", "DENY"}
  ]

  @impl Plug
  def init([]), do: []

  @impl Plug
  def call(%Plug.Conn{method: "GET"} = conn, []) do
    conn = fetch_query_params(conn)

    case under(conn.path_info, Callback.prefix()) do
      ["callback", provider] -> callback(conn, provider)
      ["check"] -> checked(conn)
      _elsewhere -> page(conn, 404, "Nothing here.")
    end
  end

  def call(conn, []), do: page(conn, 404, "Nothing here.")

  defp under(path, []), do: path
  defp under([segment | path], [segment | prefix]), do: under(path, prefix)
  defp under(_path, _prefix), do: :elsewhere

  defp callback(conn, provider) do
    case WardrikOAuth.Provider.fetch(provider) do
      {:ok, _provider} ->
        {status, message} = Callback.answer(provider, conn.query_params)
        page(conn, status, message)

      :error ->
        page(conn, 404, "Nothing here.")
    end
  end

  defp checked(conn) do
    {status, text} = Callback.checked(conn.query_params)

    conn
    |> merge_resp_headers(@headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(status, text)
  end

  defp page(conn, status, message) do
    body = """
    <!doctype html><meta charset="utf-8"><title>Wardrik</title>
    <body style="font: 16px system-ui; margin: 4rem auto; max-width: 32rem">
    <p>#{Plug.HTML.html_escape(message)}</p>
    """

    conn
    |> merge_resp_headers(@headers)
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end
end
