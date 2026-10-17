defmodule WardrikSlack.HTTP do
  @moduledoc """
  What Slack sends a channel over HTTP, as the host that serves it hands it
  over, with `WardrikChannel.request/2`: its events at `events`, the app's
  Request URL under **Event Subscriptions**, and its buttons at `actions`,
  the Request URL under **Interactivity & Shortcuts**.

  Each request is checked against the channel's `signing_secret`, as Slack
  signs it, and refused where it was not, or was signed more than five
  minutes ago. Slack's check of a Request URL is answered with what it
  asked. What the rest carry is handed to `WardrikSlack.Dispatch`, under
  the channel's tasks, and Slack answered once it has been acted on, or
  after two seconds, whichever is first: Slack sends again what it is not
  answered within three seconds, so a message being asked of an agent that
  takes longer to start is answered as taken, and asked once.
  """

  alias WardrikChannel.Request
  alias WardrikChannel.Response

  # How long ago, in seconds, a request may have been signed.
  @window 300

  # How long, in milliseconds, Slack waits on what it sent being acted on.
  @wait 2_000

  @doc "Answers `request`, given the channel's options."
  @spec request(Request.t(), keyword()) :: Response.t()
  def request(%Request{} = request, opts) do
    case Keyword.fetch(opts, :signing_secret) do
      {:ok, secret} ->
        if signed?(request, secret),
          do: route(request, opts),
          else: Response.text(401, "Slack did not sign this.")

      :error ->
        Response.text(404, "This channel takes nothing from Slack over HTTP.")
    end
  end

  defp route(%Request{method: "POST", path: ["events"], body: body}, opts) do
    case JSON.decode(body) do
      {:ok, %{"type" => "url_verification", "challenge" => challenge}} ->
        Response.json(200, %{challenge: challenge})

      {:ok, %{"type" => "event_callback"} = callback} ->
        acted(fn -> WardrikSlack.Dispatch.event(callback, opts) end)

      _other ->
        Response.text(200, "")
    end
  end

  defp route(%Request{method: "POST", path: ["actions"], body: body}, opts) do
    with %{"payload" => text} <- URI.decode_query(body),
         {:ok, payload} <- JSON.decode(text) do
      acted(fn -> WardrikSlack.Dispatch.interactive(payload, opts) end)
    else
      _unreadable -> Response.text(400, "That is not a payload Slack sends.")
    end
  end

  defp route(_request, _opts), do: Response.text(404, "Slack sends nothing here.")

  defp acted(act) do
    task = Task.Supervisor.async_nolink(WardrikChannel.tasks(), act)
    if Task.yield(task, @wait) == nil, do: Task.ignore(task)
    Response.text(200, "")
  end

  defp signed?(request, secret) do
    with at when is_binary(at) <- Request.header(request, "x-slack-request-timestamp"),
         "v0=" <> _hex = given <- Request.header(request, "x-slack-signature"),
         {at, ""} <- Integer.parse(at),
         true <- abs(System.os_time(:second) - at) <= @window do
      expected =
        "v0=" <>
          Base.encode16(:crypto.mac(:hmac, :sha256, secret, "v0:#{at}:#{request.body}"),
            case: :lower
          )

      byte_size(given) == byte_size(expected) and :crypto.hash_equals(given, expected)
    else
      _unsigned -> false
    end
  end
end
