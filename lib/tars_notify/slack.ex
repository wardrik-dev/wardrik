defmodule TarsNotify.Slack do
  @moduledoc """
  Posts each notice to a Slack channel, with Approve and Deny buttons on a
  parked turn's calls.

      ops: {TarsNotify.Slack,
        channel: "#ops",
        token: "xoxb-…",
        app_token: "xapp-…",
        approvers: ["U012ABCDEF"]}

  `:token` is a bot token with `chat:write`, and the bot must be in
  `:channel`. The buttons need `:app_token`, an app-level token with
  `connections:write` for an app with Socket Mode and interactivity on:
  `TarsNotify.Slack.Socket` holds a connection out to Slack and answers each
  click, so the daemon opens no port for it. Without one, the message says
  how to answer from a shell instead.

  Anyone in the channel may press a button unless `:approvers` lists the
  Slack user ids that may. A press decides the call with
  `Tars.Agent.decide/2`, and the message then says who decided it.

  The app should be Tars's own. Slack spreads an app's Socket Mode envelopes
  across every connection open for it, and the daemon acknowledges each one
  it receives, so an app another service also connects with loses envelopes
  to the daemon, and the daemon's button presses to the service.
  """

  @behaviour TarsNotify

  require Logger

  alias TarsNotify.Notice

  @api "https://slack.com/api/"
  @max_arguments 1_500
  @max_text 2_900

  @impl TarsNotify
  def deliver(%Notice{} = notice, opts) do
    message = %{
      channel: Keyword.fetch!(opts, :channel),
      text: summary(notice),
      blocks: blocks(notice, opts)
    }

    with {:ok, _reply} <- post("chat.postMessage", Keyword.fetch!(opts, :token), message), do: :ok
  end

  @doc "The app-level tokens of every Slack target, each once."
  @spec app_tokens() :: [String.t()]
  def app_tokens do
    for {_name, {__MODULE__, opts}} <- TarsNotify.Config.targets(),
        token = opts[:app_token],
        uniq: true,
        do: token
  end

  # -- messages --------------------------------------------------------------

  defp summary(%Notice{kind: :parked} = notice),
    do: "#{notice.agent} is waiting on you: " <> Enum.map_join(notice.calls, ", ", & &1.name)

  defp summary(%Notice{kind: :failed} = notice), do: "#{notice.agent} failed"
  defp summary(%Notice{kind: :finished} = notice), do: "#{notice.agent} answered"

  @doc false
  @spec blocks(Notice.t(), keyword()) :: [map()]
  def blocks(%Notice{kind: :parked} = notice, opts) do
    [section("*#{notice.agent}* is waiting on you.")] ++
      Enum.flat_map(notice.calls, &call_blocks(&1, notice.agent, opts))
  end

  def blocks(%Notice{kind: :failed} = notice, _opts) do
    [
      section(
        "*#{notice.agent}* failed:\n```#{clip(Notice.reason_text(notice.reason), @max_text)}```"
      )
    ]
  end

  def blocks(%Notice{kind: :finished} = notice, _opts) do
    [section("*#{notice.agent}* answered:"), section(clip(notice.text || "(nothing)", @max_text))]
  end

  defp call_blocks(call, agent, opts) do
    arguments = clip(JSON.encode!(call.arguments), @max_arguments)
    question = section("`#{call.name}`  #{call.prompt}\n```#{arguments}```")

    if opts[:app_token] do
      value = JSON.encode!(%{a: agent, c: call.id, n: call.name, t: opts[:target]})

      [
        question,
        %{
          type: "actions",
          block_id: "tars:" <> call.id,
          elements: [
            button("Approve", "tars_approve", "primary", value),
            button("Deny", "tars_deny", "danger", value)
          ]
        }
      ]
    else
      [
        question,
        context(
          "Answer with `tars approve #{agent} #{call.id}` or `tars deny #{agent} #{call.id}`."
        )
      ]
    end
  end

  defp section(text), do: %{type: "section", text: %{type: "mrkdwn", text: text}}
  defp context(text), do: %{type: "context", elements: [%{type: "mrkdwn", text: text}]}

  defp button(label, action, style, value) do
    %{
      type: "button",
      text: %{type: "plain_text", text: label},
      style: style,
      action_id: action,
      value: value
    }
  end

  defp clip(text, max) do
    if String.length(text) > max, do: String.slice(text, 0, max) <> "…", else: text
  end

  # -- answers ---------------------------------------------------------------

  @doc """
  Answers a button press, from the `block_actions` payload Slack sends over
  Socket Mode: decides the call, and replaces the message's buttons with who
  decided it, or tells the person pressing why nothing happened.
  """
  @spec answer(map()) :: :ok | :ignored
  def answer(%{"actions" => [%{"action_id" => action, "value" => value} | _]} = payload)
      when action in ["tars_approve", "tars_deny"] do
    user = Map.get(payload, "user", %{})

    with {:ok, %{"a" => agent, "c" => call, "n" => name, "t" => target}} <- JSON.decode(value),
         {:ok, {__MODULE__, opts}} <- TarsNotify.Config.target(target) do
      reply =
        if approver?(user, opts),
          do: decide(payload, action, user, agent, call, name),
          else: ephemeral("Only this channel's approvers can answer that.")

      respond(payload["response_url"], reply)
    else
      _unreadable -> :ignored
    end
  end

  def answer(_payload), do: :ignored

  defp approver?(user, opts) do
    case opts[:approvers] do
      approvers when is_list(approvers) and approvers != [] -> user["id"] in approvers
      _anyone -> true
    end
  end

  defp decide(payload, action, user, agent, call, name) do
    decision =
      if action == "tars_approve",
        do: :approve,
        else: {:deny, "Denied in Slack by #{user["username"] || user["name"] || user["id"]}."}

    by = %Tars.Principal{type: :slack, id: user["id"], name: user["username"] || user["name"]}

    case Tars.Agent.decide(agent, %{call => decision}, by: by) do
      :ok -> decided(payload, action, user, call, name)
      {:error, :not_found} -> ephemeral("#{agent} is not running.")
      {:error, _not_waiting} -> ephemeral("That was already answered.")
    end
  end

  # The message keeps what it asked, and the answered call's buttons give way
  # to who answered it.
  defp decided(payload, action, user, call, name) do
    verb = if action == "tars_approve", do: "Approved", else: "Denied"
    line = context("#{verb} `#{name}` — <@#{user["id"]}>")

    blocks =
      payload
      |> get_in(["message", "blocks"])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"block_id" => "tars:" <> ^call} -> [line]
        block -> [block]
      end)

    %{replace_original: true, text: "#{verb} #{name}", blocks: blocks}
  end

  defp ephemeral(text), do: %{response_type: "ephemeral", replace_original: false, text: text}

  defp respond(nil, _reply), do: :ok

  defp respond(url, reply) do
    case Req.post(url, Keyword.merge([json: reply], TarsNotify.Config.req_options())) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      other ->
        Logger.warning("Could not update a Slack message: #{inspect(other)}")
        :ok
    end
  end

  # -- the Web API -----------------------------------------------------------

  @doc "Calls the Web API's `method` with `token`, answering Slack's reply."
  @spec post(String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def post(method, token, body) do
    options = Keyword.merge([json: body, auth: {:bearer, token}], TarsNotify.Config.req_options())

    case Req.post(@api <> method, options) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true} = reply}} -> {:ok, reply}
      {:ok, %Req.Response{body: %{"error" => error}}} -> {:error, error}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
