defmodule WardrikChannel.Requests do
  @moduledoc """
  What each channel's medium sends it over HTTP, such as Slack's events, at
  `/v1/channels/{channel}/{path}`: the route `WardrikChannel.attach/2`
  registers among its host's, as a plug its settings are the options of.
  It hands each request to `WardrikChannel.request/2` with the channel,
  made on the host it is served on, as it was sent, and sends back what the
  channel answers. It reads at most 1 MB of what it was sent. A channel the
  host does not run, and a request that is not a POST, is answered 404.
  """

  @behaviour Plug

  import Plug.Conn

  alias WardrikChannel.Response

  @most 1_048_576

  @impl Plug
  def init(settings), do: settings

  @impl Plug
  def call(
        %Plug.Conn{method: "POST", path_info: ["v1", "channels", name | path]} = conn,
        settings
      ) do
    channels = WardrikChannel.channels(settings, host: conn.private.wardrik_host)

    with {:ok, channel} <- Map.fetch(channels, name),
         {:ok, body, conn} <- read_body(conn, length: @most) do
      conn = fetch_query_params(conn)

      answer =
        WardrikChannel.request(channel, %{
          method: conn.method,
          path: path,
          query: conn.query_params,
          headers: conn.req_headers,
          body: body
        })

      sent(conn, answer)
    else
      :error ->
        sent(conn, refused(404, "not_found", "No channel #{name} takes requests here."))

      {:more, _read, conn} ->
        sent(conn, refused(413, "invalid_request", "A request to a channel is at most 1 MB."))
    end
  end

  def call(conn, _settings),
    do:
      sent(conn, refused(404, "not_found", "No such route: #{conn.method} #{conn.request_path}"))

  defp refused(status, type, message),
    do: Response.json(status, Wardrik.JSON.error(type, message))

  defp sent(conn, %Response{status: status, headers: headers, body: body}),
    do: conn |> merge_resp_headers(headers) |> send_resp(status, body)
end
