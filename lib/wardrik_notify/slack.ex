defmodule WardrikNotify.Slack do
  @moduledoc """
  Posts each notice to a Slack channel, with Approve and Deny buttons on a
  parked turn's calls.

      ops: {WardrikNotify.Slack,
        channel: "#ops",
        token: "xoxb-…",
        app_token: "xapp-…",
        approvers: ["U012ABCDEF"]}

  `:token` is a bot token with `chat:write`, and the bot must be in
  `:channel`. The buttons need `:app_token`, an app-level token with
  `connections:write` for an app with Socket Mode and interactivity on:
  `WardrikNotify.Slack.Socket` holds a connection out to Slack and answers each
  click, so the daemon opens no port for it. Without one, the message says
  how to answer from a shell instead.

  Anyone in the channel may press a button unless `:approvers` lists the
  Slack user ids that may. A press decides the call with
  `Wardrik.Agent.decide/2`, and the message then says who decided it.

  A call waiting on a person to connect an account is posted without where to
  connect it, with Show link and Deny buttons. Show link answers the person
  pressing, and no one else, with the link and any code to enter there, read
  from the agent as they press it; the channel's history never holds it.
  Without an app token, the message says to find it with `wardrik parked`.

  The app should be Wardrik's own. Slack spreads an app's Socket Mode envelopes
  across every connection open for it, and the daemon acknowledges each one
  it receives, so an app another service also connects with loses envelopes
  to the daemon, and the daemon's button presses to the service.
  """

  @behaviour WardrikNotify

  require Logger

  alias WardrikNotify.Notice

  @api "https://slack.com/api/"
  @max_arguments 1_500
  @max_text 2_900

  @impl WardrikNotify
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
    for {_name, {__MODULE__, opts}} <- WardrikNotify.Config.targets(),
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
        %{type: "actions", block_id: "wardrik:" <> call.id, elements: buttons(call, value)}
      ]
    else
      [question, context(from_a_shell(call, agent))]
    end
  end

  defp buttons(%{authorization: true}, value),
    do: [
      button("Show link", "wardrik_link", "primary", value),
      button("Deny", "wardrik_deny", "danger", value)
    ]

  defp buttons(_call, value),
    do: [
      button("Approve", "wardrik_approve", "primary", value),
      button("Deny", "wardrik_deny", "danger", value)
    ]

  defp from_a_shell(%{authorization: true} = call, agent),
    do: "Find the link with `wardrik parked`, or refuse with `wardrik deny #{agent} #{call.id}`."

  defp from_a_shell(call, agent),
    do: "Answer with `wardrik approve #{agent} #{call.id}` or `wardrik deny #{agent} #{call.id}`."

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
  decided it; or, for Show link, tells the person pressing alone where to
  connect the account; or tells them why nothing happened.
  """
  @spec answer(map()) :: :ok | :ignored
  def answer(%{"actions" => [%{"action_id" => action, "value" => value} | _]} = payload)
      when action in ["wardrik_approve", "wardrik_deny", "wardrik_link"] do
    user = Map.get(payload, "user", %{})

    with {:ok, %{"a" => agent, "c" => call, "n" => name, "t" => target}} <- JSON.decode(value),
         {:ok, {__MODULE__, opts}} <- WardrikNotify.Config.target(target) do
      reply =
        cond do
          not approver?(user, opts) -> ephemeral("Only this channel's approvers can answer that.")
          action == "wardrik_link" -> ephemeral(link(agent, call))
          true -> decide(payload, action, user, agent, call, name)
        end

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

  # Read from the agent as the person presses, so it is never in a message
  # anyone else can see.
  defp link(agent, call) do
    case Wardrik.Agent.parked(agent) do
      {:error, :not_found} -> "#{agent} is not running."
      calls -> calls |> Enum.find(fn {parked, _prompt} -> parked.id == call end) |> link_text()
    end
  end

  defp link_text({%{link: %{url: url, code: code}}, _prompt}) when is_binary(code),
    do: "Enter `#{code}` at #{url}"

  defp link_text({%{link: %{url: url}}, _prompt}), do: "Open #{url}"
  defp link_text(_answered), do: "That is no longer waiting on anyone to connect."

  defp decide(payload, action, user, agent, call, name) do
    decision =
      if action == "wardrik_approve",
        do: :approve,
        else: {:deny, "Denied in Slack by #{user["username"] || user["name"] || user["id"]}."}

    by = %Wardrik.Principal{type: :slack, id: user["id"], name: user["username"] || user["name"]}

    case Wardrik.Agent.decide(agent, %{call => decision}, by: by) do
      :ok -> decided(payload, action, user, call, name)
      {:error, :not_found} -> ephemeral("#{agent} is not running.")
      {:error, :unrecorded} -> ephemeral("#{agent} could not record that, so it was not taken.")
      {:error, _not_waiting} -> ephemeral("That was already answered.")
    end
  end

  # The message keeps what it asked, and the answered call's buttons give way
  # to who answered it.
  defp decided(payload, action, user, call, name) do
    verb = if action == "wardrik_approve", do: "Approved", else: "Denied"
    line = context("#{verb} `#{name}` — <@#{user["id"]}>")

    blocks =
      payload
      |> get_in(["message", "blocks"])
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"block_id" => "wardrik:" <> ^call} -> [line]
        block -> [block]
      end)

    %{replace_original: true, text: "#{verb} #{name}", blocks: blocks}
  end

  defp ephemeral(text), do: %{response_type: "ephemeral", replace_original: false, text: text}

  defp respond(nil, _reply), do: :ok

  defp respond(url, reply) do
    case Req.post(url, Keyword.merge([json: reply], WardrikNotify.Config.req_options())) do
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
    options =
      Keyword.merge([json: body, auth: {:bearer, token}], WardrikNotify.Config.req_options())

    case Req.post(@api <> method, options) do
      {:ok, %Req.Response{status: 200, body: %{"ok" => true} = reply}} -> {:ok, reply}
      {:ok, %Req.Response{body: %{"error" => error}}} -> {:error, error}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
