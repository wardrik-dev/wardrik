defmodule WardrikSlack.API do
  @moduledoc """
  Calls Slack's Web API.

  Merges in the channel's `:req_options`. Retries rate-limited, 5xx and dropped requests up to five
  times.
  """

  require Logger

  @api "https://slack.com/api/"
  @retried [retry: :transient, max_retries: 5]

  @doc """
  Calls `method` with `:token`, and `:body` as JSON. Returns Slack's reply, or its `error`.

      WardrikSlack.API.post("auth.test", token: token, body: %{})

  `:req_options` are merged into the request. `[]` unless set.
  """
  @spec post(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def post(method, args),
    do: call(method, [json: Keyword.fetch!(args, :body)] ++ sent(args))

  @doc """
  Calls `method` with `:token`, and `:params` as a form. Drops `nil` params. Takes `:req_options`.
  """
  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(method, args) do
    form = for {key, value} <- Keyword.fetch!(args, :params), value != nil, do: {key, value}
    call(method, [form: form] ++ sent(args))
  end

  defp sent(args),
    do: [auth: {:bearer, Keyword.fetch!(args, :token)}] ++ Keyword.get(args, :req_options, [])

  @doc "Like `post/2`, with the bot token and `:req_options` of `workspace`."
  @spec post_in(WardrikChannel.Workspace.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def post_in(
        %WardrikChannel.Workspace{channel: channel, installation: installation},
        method,
        body
      ),
      do: post(method, token: installation.token, body: body, req_options: req_options(channel))

  @doc "Like `read/2`, with the bot token and `:req_options` of `workspace`."
  @spec read_in(WardrikChannel.Workspace.t(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def read_in(
        %WardrikChannel.Workspace{channel: channel, installation: installation},
        method,
        params
      ),
      do:
        read(method, token: installation.token, params: params, req_options: req_options(channel))

  @doc "Returns the channel's `:req_options`. `[]` unless set."
  @spec req_options(WardrikChannel.Channel.t()) :: keyword()
  def req_options(%WardrikChannel.Channel{options: options}),
    do: Keyword.get(options, :req_options, [])

  @doc """
  Calls `method` with `Req` options.

  Returns `{:ok, reply}` when Slack answers `"ok": true`, `{:error, error}` with Slack's `error`,
  `{:error, {:status, status}}` for any other status, or Req's error.
  """
  @spec call(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(method, options) do
    case Req.post(@api <> method, @retried ++ options) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true} = reply}} -> {:ok, reply}
      {:ok, %Req.Response{body: %{"error" => error}}} -> {:error, error}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Posts `reply` to a button press's `response_url`.

  The reply replaces the message, or is shown only to the person who pressed. Always returns `:ok`.
  A failure is logged, since the press was already acted on.
  """
  @spec respond(String.t() | nil, map(), keyword()) :: :ok
  def respond(nil, _reply, _req_options), do: :ok

  def respond(url, reply, req_options) do
    case Req.post(url, [json: reply] ++ @retried ++ req_options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
      other -> Logger.warning("Slack didn't take an answer to a button: #{inspect(other)}")
    end

    :ok
  end
end
