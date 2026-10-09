defmodule WardrikSlack do
  @moduledoc """
  The Slack adapter of `WardrikChannel`: a channel that is one Slack app,
  `type: slack` in `config.yaml`.

      channels:
        slack:
          type: slack
          token: ${SLACK_BOT_TOKEN}
          app_token: ${SLACK_APP_TOKEN}

  `token` is the app's bot token, `xoxb-…`, which posts. `app_token` is an
  app-level token, `xapp-…`, with `connections:write`, for Socket Mode: a
  connection the node opens out to Slack, so it needs no public address and no
  open port. Without it, nothing posted can be answered from Slack.
  `WardrikSlack.Socket` holds the connection, and `WardrikSlack.Answers`
  answers each button press.

  A room is a Slack channel, by its name, `#ops`, or its id. A notice reads
  as `WardrikSlack.Notices` lays it out.

  Each workspace is a channel of its own, with an app of its own. The app
  should be Wardrik's alone: Slack spreads an app's Socket Mode envelopes
  across every connection open for it, and each is acknowledged where it
  lands, so an app another service also connects with loses envelopes to
  Wardrik, and Wardrik's button presses to the service.
  """

  @behaviour WardrikChannel

  require Logger

  alias WardrikChannel.Outbound

  @api "https://slack.com/api/"

  @impl WardrikChannel
  def config(settings) do
    case Map.keys(settings) -- ~w(token app_token) do
      [] -> tokens(settings)
      [key | _] -> {:error, [key], "is not a setting; expected token or app_token"}
    end
  end

  defp tokens(%{"token" => token} = settings) when is_binary(token) and token != "" do
    case settings["app_token"] do
      nil -> {:ok, [token: token]}
      app_token when is_binary(app_token) -> {:ok, [token: token, app_token: app_token]}
      _other -> {:error, ["app_token"], "is the app's app-level token, xapp-…"}
    end
  end

  defp tokens(_settings), do: {:error, ["token"], "is required: the app's bot token, xoxb-…"}

  @impl WardrikChannel
  def child_spec(opts), do: WardrikSlack.Socket.child_spec(opts)

  @impl WardrikChannel
  def deliver(%Outbound{room: room, body: {:notice, notice}} = outbound, opts) do
    message =
      WardrikSlack.Notices.message(notice,
        buttons: opts[:app_token] != nil,
        approvers: outbound.approvers
      )

    post(
      "chat.postMessage",
      Keyword.fetch!(opts, :token),
      Map.put(message, :channel, room),
      Keyword.get(opts, :req_options, [])
    )
  end

  @doc "A row of buttons, or other elements, under `block_id`."
  @spec actions(String.t(), [map()]) :: map()
  def actions(block_id, elements), do: %{type: "actions", block_id: block_id, elements: elements}

  @doc "A reply the person who pressed a button sees alone."
  @spec ephemeral(String.t()) :: map()
  def ephemeral(text), do: %{response_type: "ephemeral", replace_original: false, text: text}

  @doc """
  Answers a button press at its `response_url` with `reply`, which replaces
  the message or is seen by the presser alone, as it says. A failure is
  logged, since the press has been acted on either way.
  """
  @spec respond(String.t() | nil, map(), keyword()) :: :ok
  def respond(nil, _reply, _req_options), do: :ok

  def respond(url, reply, req_options) do
    case Req.post(url, Keyword.merge([json: reply], req_options)) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      other ->
        Logger.warning("Could not update a Slack message: #{inspect(other)}")
        :ok
    end
  end

  @doc """
  Calls the Web API's `method` with `token`, answering Slack's reply.
  `req_options` are merged into the request.
  """
  @spec post(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(method, token, body, req_options \\ []) do
    options = Keyword.merge([json: body, auth: {:bearer, token}], req_options)

    case Req.post(@api <> method, options) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true} = reply}} -> {:ok, reply}
      {:ok, %Req.Response{body: %{"error" => error}}} -> {:error, error}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
