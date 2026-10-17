defmodule WardrikSlack do
  @moduledoc """
  The Slack adapter of `WardrikChannel`: a channel that is one Slack app,
  `type: slack` in `config.yaml`, in each workspace it is installed in.

      channels:
        slack:
          type: slack
          token: ${SLACK_BOT_TOKEN}
          signing_secret: ${SLACK_SIGNING_SECRET}

  Slack sends the app what happens over HTTP, `WardrikSlack.HTTP`, to the
  Request URL the app names: its events under `events`, and its buttons
  under `actions`, each signed with the app's `signing_secret`, under
  **Basic Information**. For testing without a public address,
  `app_token`, an app-level token, `xapp-…`, with `connections:write`, has
  `WardrikSlack.Socket` take them over Socket Mode instead, a connection the
  node opens out to Slack. Without either, nothing posted can be answered
  from Slack.

  `token`, the app's bot token, `xoxb-…`, installs it in the one workspace
  that token reaches. An app installed in many, one for each owner, names
  its `client_id` and `client_secret`, under **Basic Information**: the
  host sends someone to `WardrikChannel.install_url/3` to add it to a
  workspace of theirs, and hands Slack sending them back, to the app's
  Redirect URL, to `WardrikChannel.install/3`; see `WardrikSlack.Install`.

  A room is a Slack channel, by its name, `#ops`, or its id, and a thread one
  under a message there. A notice reads as `WardrikSlack.Notices` lays it
  out; what an agent answers in a thread is posted as Markdown, which Slack
  renders, and `WardrikSlack.Threads` marks the messages it answers.

  The calls a thread's agent waits on are asked of the channel's approvers
  directly, where it names any: each is sent them in the app's own messages
  with them, with a link to the thread, and the thread says who it waits
  on. `WardrikSlack.Approvers` finds each as a member. Where none can be
  reached, the calls are asked in the thread.

  Over Socket Mode, the app should be Wardrik's alone: Slack spreads an
  app's Socket Mode envelopes across every connection open for it, and each
  is acknowledged where it lands, so an app another service also connects
  with loses envelopes to Wardrik, and Wardrik's button presses to the
  service.
  """

  @behaviour WardrikChannel

  require Logger

  alias WardrikChannel.Installation
  alias WardrikChannel.Member
  alias WardrikChannel.Outbound

  @api "https://slack.com/api/"
  @max_markdown 12_000

  # Each setting, the option it is, and what it is.
  @settings %{
    "app_token" => {:app_token, "the app's app-level token, xapp-…"},
    "signing_secret" => {:signing_secret, "the app's signing secret"},
    "client_id" => {:client_id, "the app's client ID"},
    "client_secret" => {:client_secret, "the app's client secret"}
  }

  @impl WardrikChannel
  def config(settings) do
    with :ok <- known(Map.keys(settings) -- Map.keys(@settings)),
         :ok <- texts(settings),
         do: paired(Map.new(settings, fn {key, value} -> {option(key), value} end))
  end

  defp option(key), do: elem(Map.fetch!(@settings, key), 0)
  defp what(key), do: elem(Map.fetch!(@settings, key), 1)

  defp known([]), do: :ok

  defp known([key | _]),
    do:
      {:error, [key],
       "is not a setting; expected app_token, signing_secret, client_id or client_secret"}

  defp texts(settings) do
    case Enum.find(settings, fn {_key, value} -> not is_binary(value) or value == "" end) do
      nil -> :ok
      {key, _value} -> {:error, [key], "is #{what(key)}"}
    end
  end

  defp paired(%{client_id: _id, client_secret: _secret} = options),
    do: {:ok, Keyword.new(options)}

  defp paired(%{client_id: _id}),
    do: {:error, ["client_secret"], "is required with client_id: #{what("client_secret")}"}

  defp paired(%{client_secret: _secret}),
    do: {:error, ["client_id"], "is required with client_secret: #{what("client_id")}"}

  defp paired(options), do: {:ok, Keyword.new(options)}

  @impl WardrikChannel
  def child_spec(opts), do: WardrikSlack.Socket.child_spec(opts)

  @doc """
  Whether `names`, each a `@handle`, an email address or a member id,
  include `member`, as `WardrikSlack.Approvers` finds them in its
  workspace.
  """
  @impl WardrikChannel
  def include?(names, %Member{installation: installation, id: id}, opts),
    do:
      WardrikSlack.Approvers.include?(names, id,
        token: installation.token,
        req_options: req_options(opts)
      )

  @impl WardrikChannel
  def request(request, opts), do: WardrikSlack.HTTP.request(request, opts)

  @impl WardrikChannel
  def install_url(owner, opts), do: WardrikSlack.Install.url(owner, opts)

  @impl WardrikChannel
  def install(owner, request, opts), do: WardrikSlack.Install.installed(owner, request, opts)

  @doc """
  The user id of the bot the installation posts as, asked of Slack once
  for each workspace while the node runs.
  """
  @spec bot(Installation.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def bot(%Installation{} = installation, req_options) do
    key = {__MODULE__, :bot, installation.channel, installation.workspace}

    case :persistent_term.get(key, nil) do
      nil ->
        with {:ok, %{"user_id" => bot}} <- post("auth.test", installation.token, %{}, req_options) do
          :persistent_term.put(key, bot)
          {:ok, bot}
        end

      bot ->
        {:ok, bot}
    end
  end

  @doc "Whether what is posted can be answered from Slack, over HTTP or Socket Mode."
  @spec answered?(keyword()) :: boolean()
  def answered?(opts),
    do: Keyword.has_key?(opts, :signing_secret) or Keyword.has_key?(opts, :app_token)

  @impl WardrikChannel
  def deliver(%Outbound{installation: installation} = outbound, opts),
    do: post_out(outbound, [token: installation.token] ++ opts)

  defp post_out(%Outbound{to: :approvers, approvers: [_ | _], thread: thread} = outbound, opts)
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

        post_out(%{outbound | to: :room}, opts)

      _asked ->
        posted(%{text: waiting(outbound.approvers, notice)}, outbound, opts)
    end
  end

  defp post_out(%Outbound{body: {:notice, notice}} = outbound, opts) do
    notice
    |> WardrikSlack.Notices.message(buttons: answered?(opts))
    |> posted(outbound, opts)
  end

  defp post_out(%Outbound{room: room, body: {:reply, text, answering}} = outbound, opts) do
    with {:ok, posted} <- posted(reply(text), outbound, opts) do
      :ok = WardrikSlack.Threads.answered(room, answering, opts)
      {:ok, posted}
    end
  end

  defp asked?({approver, :error}, _notice, _from, _outbound, _opts) do
    Logger.warning("Slack has no member #{approver}, so they are not asked directly")
    false
  end

  defp asked?({approver, {:ok, member}}, notice, from, _outbound, opts) do
    %{text: text, blocks: [heading | rest]} =
      WardrikSlack.Notices.message(notice, buttons: answered?(opts))

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

  @doc """
  Calls the Web API's `method` with `options` as Req takes them, such as
  a form, answering Slack's reply.
  """
  @spec call(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(method, options) do
    case Req.post(@api <> method, options) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true} = reply}} -> {:ok, reply}
      {:ok, %Req.Response{body: %{"error" => error}}} -> {:error, error}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
