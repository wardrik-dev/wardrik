defmodule WardrikOAuth.Callback.Page do
  @moduledoc """
  The pages `WardrikOAuth.Callback` describes, as a plug a host serves where
  `WardrikOAuth.Callback.pages/1` says, handed the request with its path as
  it came: a callback for each provider configured, `check`, and a 404 for
  anything else. What is shown is HTML-escaped, and every page is kept
  from caches, referrers and frames, and loads nothing.

      {WardrikOAuth.Callback.Page, oauth: oauth}
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
  def init(opts), do: Keyword.validate!(opts, [:oauth])

  @impl Plug
  def call(%Plug.Conn{method: "GET"} = conn, oauth: oauth) do
    conn = fetch_query_params(conn)

    case under(conn.path_info, Callback.prefix(oauth)) do
      ["callback", provider] -> callback(conn, oauth, provider)
      ["check"] -> checked(conn)
      _elsewhere -> page(conn, 404, "Nothing here.")
    end
  end

  def call(conn, _opts), do: page(conn, 404, "Nothing here.")

  defp under(path, []), do: path
  defp under([segment | path], [segment | prefix]), do: under(path, prefix)
  defp under(_path, _prefix), do: :elsewhere

  defp callback(conn, oauth, provider) do
    if provider in WardrikOAuth.Provider.names(oauth) do
      {status, message} = Callback.answer(provider, conn.query_params)
      page(conn, status, message)
    else
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
