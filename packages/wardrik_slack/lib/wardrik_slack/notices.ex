defmodule WardrikSlack.Notices do
  @moduledoc """
  How a `WardrikNotify.Notice` reads in Slack: a parked turn's calls, each
  with Approve and Deny buttons, a failure, or what a turn answered, as the
  Markdown a model writes, which Slack renders.

  The buttons are there where the channel has an app-level token, so a
  press reaches it: without one, the message says how to answer from a shell
  instead. Each call waiting on approval has a box above its buttons for a
  note to the agent, sent with either button: Approve hands it to the agent
  with the call's answer, as `wardrik approve` does a note, and Deny tells
  it the note as why, as `wardrik deny` does a reason, so either can steer
  what it does next. A note never changes the call, which runs as it was
  written.

  A call waiting on a person to connect an account is posted without where to
  connect it, with Show link and Deny buttons. Show link answers the person
  pressing, and no one else, with the link and any code to enter there, read
  from the agent as they press it; the channel's history never holds it.

  An agent answering in a thread is named as the agent the thread is under.
  Each button carries the agent and the call it answers, which
  `WardrikSlack.Answers` reads back: Slack hands back a button as the bot
  posted it, and nobody else can change a bot's message.
  """

  alias WardrikNotify.Notice

  @note "wardrik-note:"
  @max_arguments 1_500
  @max_text 2_900

  @doc """
  The message that posts `notice`: its text and its blocks. `:buttons`
  says whether a press can reach the channel.
  """
  @spec message(Notice.t(), keyword()) :: %{text: String.t(), blocks: [map()]}
  def message(%Notice{} = notice, opts),
    do: %{text: summary(notice), blocks: blocks(notice, opts)}

  @doc "The id of the box a note on a parked call's decision is written in."
  @spec note_block(String.t()) :: String.t()
  def note_block(call_id), do: @note <> call_id

  # -- messages --------------------------------------------------------------

  defp summary(%Notice{kind: :parked} = notice),
    do:
      "#{shown(notice.agent)} is waiting on you: " <> Enum.map_join(notice.calls, ", ", & &1.name)

  defp summary(%Notice{kind: :failed} = notice), do: "#{shown(notice.agent)} failed"
  defp summary(%Notice{kind: :finished} = notice), do: "#{shown(notice.agent)} answered"

  @doc false
  @spec blocks(Notice.t(), keyword()) :: [map()]
  def blocks(%Notice{kind: :parked} = notice, opts) do
    [section("*#{shown(notice.agent)}* is waiting on you.")] ++
      Enum.flat_map(notice.calls, &call_blocks(&1, notice.agent, opts))
  end

  def blocks(%Notice{kind: :failed} = notice, _opts) do
    [
      section(
        "*#{shown(notice.agent)}* failed:\n```#{clip(Notice.reason_text(notice.reason), @max_text)}```"
      )
    ]
  end

  def blocks(%Notice{kind: :finished} = notice, _opts) do
    [
      section("*#{shown(notice.agent)}* answered:"),
      WardrikSlack.markdown(notice.text || "(nothing)")
    ]
  end

  defp read(%{labels: [_ | _] = labels}),
    do: "\n_It has read #{Wardrik.Label.described(labels)}, which may be what asked for this._"

  defp read(_call), do: ""

  defp call_blocks(call, agent, opts) do
    arguments = clip(JSON.encode!(call.arguments), @max_arguments)
    question = section("`#{call.name}`  #{call.prompt}#{read(call)}\n```#{arguments}```")

    if opts[:buttons] do
      value = JSON.encode!(%{a: to_string(agent), c: call.id, n: call.name})

      [question] ++
        note_box(call) ++
        [WardrikSlack.actions("wardrik:" <> call.id, buttons(call, value))]
    else
      [question, context(from_a_shell(call, agent))]
    end
  end

  # A call waiting on a connection has no approval to steer.
  defp note_box(%{authorization: true}), do: []

  defp note_box(call) do
    [
      %{
        type: "input",
        block_id: note_block(call.id),
        optional: true,
        label: %{type: "plain_text", text: "A note for the agent, sent with either button"},
        element: %{type: "plain_text_input", action_id: "note", multiline: true}
      }
    ]
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

  # An agent answering in a thread is named as the one the thread is under;
  # its buttons and commands carry the thread's own.
  defp shown(agent), do: Wardrik.AgentID.put_external_id(agent, nil)

  defp section(text), do: %{type: "section", text: %{type: "mrkdwn", text: text}}

  @doc false
  @spec context(String.t()) :: map()
  def context(text), do: %{type: "context", elements: [%{type: "mrkdwn", text: text}]}

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
end
