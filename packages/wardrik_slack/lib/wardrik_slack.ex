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

  A room is a Slack channel, by its name, `#ops`, or its id, and a thread one
  under a message there. A notice reads as `WardrikSlack.Notices` lays it
  out; what an agent answers in a thread is posted as Markdown, which Slack
  renders, and `WardrikSlack.Threads` marks the messages it answers.

  The calls a thread's agent waits on are asked of the channel's approvers
  directly, where it names any: each is sent them in the app's own messages
  with them, with a link to the thread, and the thread says who it waits
  on. `WardrikSlack.Approvers` finds each as a member. Where none can be
  reached, the calls are asked in the thread.

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
  @max_markdown 12_000

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
  def deliver(%Outbound{to: :approvers, approvers: [_ | _], thread: thread} = outbound, opts)
      when is_binary(thread) do
    {:notice, notice} = outbound.body
    members = WardrikSlack.Approvers.members(outbound.approvers, opts)
    from = from(outbound, opts)

    case Enum.filter(members, &asked?(&1, notice, from, outbound, opts)) do
      [] ->
        Logger.warning(
          "Slack reached none of #{WardrikSlack.Approvers.named(outbound.approvers)}, " <>
            "so what they are asked is posted in #{outbound.room}"
        )

        deliver(%{outbound | to: :room}, opts)

      _asked ->
        posted(%{text: waiting(outbound.approvers, notice)}, outbound, opts)
    end
  end

  def deliver(%Outbound{body: {:notice, notice}} = outbound, opts) do
    notice
    |> WardrikSlack.Notices.message(
      buttons: opts[:app_token] != nil,
      approvers: outbound.approvers
    )
    |> posted(outbound, opts)
  end

  def deliver(%Outbound{room: room, body: {:reply, text, answering}} = outbound, opts) do
    with {:ok, posted} <- posted(reply(text), outbound, opts) do
      :ok = WardrikSlack.Threads.answered(room, answering, opts)
      {:ok, posted}
    end
  end

  defp asked?({approver, :error}, _notice, _from, _outbound, _opts) do
    Logger.warning("Slack has no member #{approver}, so they are not asked directly")
    false
  end

  defp asked?({approver, {:ok, member}}, notice, from, outbound, opts) do
    %{text: text, blocks: [heading | rest]} =
      WardrikSlack.Notices.message(notice,
        buttons: opts[:app_token] != nil,
        approvers: outbound.approvers
      )

    message = %{text: text, blocks: [heading, from | rest], channel: member}

    case post("chat.postMessage", Keyword.fetch!(opts, :token), message, req_options(opts)) do
      {:ok, _posted} ->
        true

      {:error, reason} ->
        Logger.warning("Slack could not message #{approver}: #{inspect(reason)}")
        false
    end
  end

  defp from(%Outbound{room: room, thread: thread}, opts) do
    shown = if String.starts_with?(room, "#"), do: room, else: "<##{room}>"

    case read(
           "chat.getPermalink",
           Keyword.fetch!(opts, :token),
           %{
             channel: room,
             message_ts: thread
           },
           req_options(opts)
         ) do
      {:ok, %{"permalink" => link}} ->
        WardrikSlack.Notices.context("From <#{link}|a thread> in #{shown}.")

      _unlinked ->
        WardrikSlack.Notices.context("From a thread in #{shown}.")
    end
  end

  defp waiting(approvers, notice) do
    asked =
      Enum.map_join(notice.calls, " and ", fn
        %{authorization: true, name: name} -> "connect an account for `#{name}`"
        %{name: name} -> "approve `#{name}`"
      end)

    "Waiting on #{WardrikSlack.Approvers.named(approvers)} to #{asked}."
  end

  defp req_options(opts), do: Keyword.get(opts, :req_options, [])

  defp reply(""), do: %{text: "_It answered nothing._"}

  defp reply(text) do
    %{text: block} = markdown = markdown(text)
    %{text: block, blocks: [markdown]}
  end

  @doc """
  A block of what an agent wrote, as the Markdown a model writes, which Slack
  renders, clipped to Slack's limit on one.
  """
  @spec markdown(String.t()) :: map()
  def markdown(text) do
    clipped =
      if String.length(text) > @max_markdown,
        do: String.slice(text, 0, @max_markdown - 1) <> "…",
        else: text

    %{type: "markdown", text: clipped}
  end

  defp posted(message, %Outbound{room: room, thread: thread}, opts) do
    message = Map.put(message, :channel, room)
    message = if thread, do: Map.put(message, :thread_ts, thread), else: message

    post("chat.postMessage", Keyword.fetch!(opts, :token), message, req_options(opts))
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
  def post(method, token, body, req_options \\ []),
    do: call(method, Keyword.merge([json: body, auth: {:bearer, token}], req_options))

  @doc """
  Calls the Web API's `method` with `token` and `params` as a form, as the
  methods that only read take them, answering Slack's reply. A `nil`
  param is left out.
  """
  @spec read(String.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(method, token, params, req_options \\ []) do
    form = for {key, value} <- params, value != nil, do: {key, value}
    call(method, Keyword.merge([form: form, auth: {:bearer, token}], req_options))
  end

  defp call(method, options) do
    case Req.post(@api <> method, options) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true} = reply}} -> {:ok, reply}
      {:ok, %Req.Response{body: %{"error" => error}}} -> {:error, error}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
