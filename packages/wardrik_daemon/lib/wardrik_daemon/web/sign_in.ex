defmodule WardrikDaemon.Web.SignIn do
  @moduledoc false
  @behaviour Plug

  import Plug.Conn

  alias WardrikDaemon.Tokens

  @impl Plug
  def init(action), do: action

  @impl Plug
  def call(conn, :show) do
    conn = fetch_query_params(conn)

    with %{"code" => code} <- conn.query_params,
         {:ok, secret} <- WardrikDaemon.Web.secret(conn.secret_key_base, code) do
      conn
      |> configure_session(renew: true)
      |> put_session("wardrik_token", secret)
      |> redirect("/web")
    else
      _none -> page(conn, conn.query_params["code"] && :expired)
    end
  end

  def call(conn, :out) do
    %{store: store} = conn.private.phoenix_endpoint.config(:daemon)

    with secret when is_binary(secret) <- get_session(conn, "wardrik_token"),
         {:ok, token} <- Tokens.verify(store, secret),
         do: Tokens.revoke(store, token.id)

    conn
    |> configure_session(drop: true)
    |> page(:out)
  end

  defp redirect(conn, to) do
    conn
    |> put_resp_header("location", to)
    |> send_resp(302, "")
    |> halt()
  end

  defp page(conn, why) do
    note =
      case why do
        :expired -> "That link has expired. Run the command again for a new one."
        :out -> "You're signed out."
        nil -> "Run this on the server to get a sign-in link:"
      end

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html(note))
    |> halt()
  end

  defp html(note) do
    """
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Sign in · Wardrik</title>
    <style>
    :root { --bg: #fff; --ink: #0b0d10; --muted: #5b636e; --line: #e4e7eb; --accent: #c2410c; --code: #14171b; }
    @media (prefers-color-scheme: dark) { :root { --bg: #0e1115; --ink: #f4f5f7; --muted: #9aa3ae; --line: #232a31; --accent: #fb8a4b; --code: #07090b; } }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--ink);
      font: 15px/1.5 Geist, Inter, ui-sans-serif, system-ui, sans-serif; padding: 16px; box-sizing: border-box; }
    main { max-width: 420px; width: 100%; border: 1px solid var(--line); border-radius: 10px; padding: 28px; }
    h1 { font-size: 20px; margin: 0 0 4px; letter-spacing: -0.02em; } h1 span { color: var(--accent); }
    p { color: var(--muted); margin: 12px 0; }
    pre { background: var(--code); color: #e6e8eb; padding: 12px 14px; border-radius: 6px; font: 13px ui-monospace, Menlo, monospace; margin: 0; }
    </style></head>
    <body><main>
    <h1>Wardrik<span>.</span> operators</h1>
    <p>#{note}</p>
    <pre>wardrik web</pre>
    </main></body></html>
    """
  end
end
