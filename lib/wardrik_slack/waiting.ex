defmodule WardrikSlack.Waiting do
  @moduledoc """
  Lays out the calls an agent waits on as one Slack message.

    * Each call shows its tool, the policy's question and its arguments, with a note box and
      Approve and Deny buttons.
    * A call waiting on a sign-in has Show link instead. It shows only the person who pressed it
      where to sign in.

  Each button's value holds the agent, the conversation, the call and who asked, for
  `WardrikSlack.Answers`.
  This is safe because only the bot can change its own messages.
  """

  alias WardrikChannel.Waiting
  alias WardrikSlack.Blocks

  @note "wardrik-note:"
  @max_arguments 1_500

  @doc "Returns the message that asks about `calls`."
  @spec message([Waiting.t()]) :: %{text: String.t(), blocks: [map()]}
  def message(calls) do
    text = "Waiting for someone to #{asked(calls)}."
    %{text: text, blocks: [Blocks.section(text) | calls_blocks(calls)]}
  end

  @doc "Returns the blocks for `calls`, each with its question and buttons."
  @spec calls_blocks([Waiting.t()]) :: [map()]
  def calls_blocks(calls), do: Enum.flat_map(calls, &blocks/1)

  @doc """
  Returns what `calls` ask for, in words.

      WardrikSlack.Waiting.asked(calls)
      #=> "approve `echo` and sign in for `mail`"
  """
  @spec asked([Waiting.t()]) :: String.t()
  def asked(calls), do: Enum.map_join(calls, " and ", &ask/1)

  @doc "Returns the block ID of the note box for the call `id`."
  @spec note_block(String.t()) :: String.t()
  def note_block(id), do: @note <> id

  @doc "Returns the block ID of the buttons for the call `id`."
  @spec buttons_block(String.t()) :: String.t()
  def buttons_block(id), do: "wardrik:" <> id

  defp ask(%Waiting{interrupt: %{reason: :authorization, name: name}}),
    do: "sign in for `#{name}`"

  defp ask(%Waiting{interrupt: %{name: name}}), do: "approve `#{name || "the model"}`"

  defp blocks(%Waiting{interrupt: interrupt} = waiting) do
    value =
      JSON.encode!(%{
        g: waiting.agent,
        c: waiting.conversation,
        i: interrupt.id,
        a: waiting.asked_by,
        n: interrupt.name || "the model"
      })

    [question(waiting)] ++
      note_box(interrupt) ++
      [Blocks.actions(buttons_block(interrupt.id), buttons(interrupt, value))]
  end

  defp question(%Waiting{interrupt: interrupt, arguments: arguments}) do
    lines = [
      "`#{interrupt.name || "the model"}`  #{interrupt.message}",
      read(interrupt.labels),
      shown(arguments)
    ]

    lines |> Enum.reject(&(&1 == "")) |> Enum.join("\n") |> Blocks.section()
  end

  defp read(labels) when is_list(labels) do
    if "outside" in labels,
      do: "_It has read content from outside, which may be what asked for this._",
      else: ""
  end

  defp read(_labels), do: ""

  defp shown(nil), do: ""
  defp shown(arguments), do: "```#{Blocks.clip(JSON.encode!(arguments), @max_arguments)}```"

  defp note_box(%{reason: :authorization}), do: []

  defp note_box(interrupt) do
    [
      %{
        type: "input",
        block_id: note_block(interrupt.id),
        optional: true,
        label: Blocks.plain("A note for the agent, sent with either button"),
        element: %{type: "plain_text_input", action_id: "note", multiline: true}
      }
    ]
  end

  defp buttons(%{reason: :authorization}, value),
    do: [
      Blocks.button("Show link", action_id: "wardrik_link", value: value, style: "primary"),
      Blocks.button("Deny", action_id: "wardrik_deny", value: value, style: "danger")
    ]

  defp buttons(_interrupt, value),
    do: [
      Blocks.button("Approve", action_id: "wardrik_approve", value: value, style: "primary"),
      Blocks.button("Deny", action_id: "wardrik_deny", value: value, style: "danger")
    ]
end
