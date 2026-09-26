defmodule TarsOAuth.Loopback.Page do
  @moduledoc """
  The pages `TarsOAuth.Loopback` serves: a callback for each provider, and a
  404 for anything else. What is shown is HTML-escaped.
  """

  use Plug.Router

  plug :match
  plug :dispatch

  get "/callback/:provider" do
    conn = fetch_query_params(conn)
    {status, message} = TarsOAuth.Loopback.answer(provider, conn.query_params)
    page(conn, status, message)
  end

  match _ do
    page(conn, 404, "Nothing here.")
  end

  defp page(conn, status, message) do
    body = """
    <!doctype html><meta charset="utf-8"><title>Tars</title>
    <body style="font: 16px system-ui; margin: 4rem auto; max-width: 32rem">
    <p>#{Plug.HTML.html_escape(message)}</p>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(status, body)
  end
end
