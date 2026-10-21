defmodule MyAppWeb.SlackController do
  use MyAppWeb, :controller

  def add(conn, _params) do
    {:ok, url} =
      WardrikChannel.install_url(MyApp.Slack.channel(), org(conn), return_to: "/settings")

    redirect(conn, external: url)
  end

  def installed(conn, _params) do
    response =
      WardrikChannel.install(MyApp.Slack.channel(), org(conn), %{
        method: conn.method,
        path: conn.path_info,
        query: conn.query_params,
        headers: conn.req_headers,
        body: ""
      })

    conn |> merge_resp_headers(response.headers) |> send_resp(response.status, response.body)
  end

  # The org the signed-in admin acts for.
  defp org(conn), do: conn.assigns.current_user.org
end
