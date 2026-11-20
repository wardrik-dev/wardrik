defmodule WardrikSlack.Notices do
  @moduledoc """
  Lays out a `Wardrik.Notice` as one Slack message.

  | Notice      | Message                                    |
  | ----------- | ------------------------------------------ |
  | `:parked`   | the waiting calls, with Approve and Deny   |
  | `:failed`   | why it failed                              |
  | `:finished` | the answer, under the agent's name         |

  Each names the agent by its name, with its ID in small text under it, or by its ID when it has
  no name. Each carries the notice's `Wardrik.Notice.json/1` payload as its message metadata, so
  a reply in its thread knows which agent and conversation it's about.
  """

  alias Wardrik.Chat.Waiting
  alias Wardrik.Notice
  alias WardrikSlack.Blocks

  @doc "Returns the message for `notice`."
  @spec message(Notice.t()) :: %{text: String.t(), blocks: [map()], metadata: map()}
  def message(%Notice{kind: :parked} = notice) do
    calls = Waiting.from_notice(notice)

    text =
      "#{label_agent(notice)} waits for someone to #{WardrikSlack.Waiting.describe_asks(calls)}."

    build_message(
      notice,
      text,
      [Blocks.section(text) | WardrikSlack.Waiting.calls_blocks(calls)] ++
        build_id_context(notice)
    )
  end

  def message(%Notice{kind: :failed} = notice) do
    text = ":warning: #{label_agent(notice)} stopped with an error: #{notice.reason}"
    build_message(notice, text, [Blocks.section(text) | build_id_context(notice)])
  end

  def message(%Notice{kind: :finished, text: text} = notice) do
    build_message(
      notice,
      Blocks.clip("#{name_agent(notice)}: #{text}", 3_000),
      [
        Blocks.context("From #{label_agent(notice)}#{append_id(notice)}"),
        Blocks.markdown(text || "")
      ]
    )
  end

  defp build_message(notice, text, blocks),
    do: %{
      text: text,
      blocks: blocks,
      metadata: %{event_type: Notice.event(notice), event_payload: drop_nils(Notice.json(notice))}
    }

  defp name_agent(%Notice{name: nil, agent: agent}), do: agent
  defp name_agent(%Notice{name: name}), do: name

  defp label_agent(%Notice{name: nil, agent: agent}), do: "`#{agent}`"
  defp label_agent(%Notice{name: name}), do: "*#{name}*"

  defp build_id_context(%Notice{name: nil}), do: []
  defp build_id_context(%Notice{agent: agent}), do: [Blocks.context("`#{agent}`")]

  defp append_id(%Notice{name: nil}), do: ""
  defp append_id(%Notice{agent: agent}), do: " · `#{agent}`"

  # Slack documents no null in metadata; it ignores metadata it can't read, and posts the message.
  defp drop_nils(map) when is_map(map),
    do: for({key, value} <- map, value != nil, into: %{}, do: {key, drop_nils(value)})

  defp drop_nils(list) when is_list(list), do: Enum.map(list, &drop_nils/1)
  defp drop_nils(value), do: value
end
