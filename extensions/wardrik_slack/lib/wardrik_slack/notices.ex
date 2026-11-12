defmodule WardrikSlack.Notices do
  @moduledoc """
  Lays out a `Wardrik.Notice` as one Slack message.

  | Notice      | Message                                                        |
  | ----------- | -------------------------------------------------------------- |
  | `:parked`   | the waiting calls, with Approve and Deny |
  | `:failed`   | why it failed                            |
  | `:finished` | the answer, under the agent's ID         |
  """

  alias Wardrik.Chat.Waiting
  alias WardrikSlack.Blocks

  @doc "Returns the message for `notice`."
  @spec message(Wardrik.Notice.t()) :: %{text: String.t(), blocks: [map()]}
  def message(%Wardrik.Notice{kind: :parked, agent: agent} = notice) do
    calls = Waiting.from_notice(notice)
    text = "`#{agent}` waits for someone to #{WardrikSlack.Waiting.asked(calls)}."
    %{text: text, blocks: [Blocks.section(text) | WardrikSlack.Waiting.calls_blocks(calls)]}
  end

  def message(%Wardrik.Notice{kind: :failed, agent: agent} = notice) do
    text = ":warning: `#{agent}` stopped with an error: #{notice.reason}"
    %{text: text, blocks: [Blocks.section(text)]}
  end

  def message(%Wardrik.Notice{kind: :finished, agent: agent, text: text}) do
    %{
      text: Blocks.clip("#{agent}: #{text}", 3_000),
      blocks: [Blocks.context("From `#{agent}`"), Blocks.markdown(text || "")]
    }
  end
end
