defmodule Wardrik.Chat.Inbound do
  @moduledoc """
  A message someone posted in a room. Adapters pass it to `Wardrik.Chat.answer_inbound/2`.

    * `:room` - the room it was posted in.
    * `:thread` - the thread it replies in, or `nil` if it starts one.
    * `:parent` - the text of the message that started `:thread`, when no agent answers in that
      thread yet, such as a notice. The agent is asked with it quoted. `nil` unless set.
    * `:parent_notice` - when `:parent` is a notice, its `Wardrik.Notice.json/1` payload. The agent
      is told which agent and conversation it's about. `nil` unless set.
    * `:id` - unique in its room. A message passed twice is answered once.
    * `:sender` - a `Wardrik.Chat.Member`.
    * `:text` - the text, without any mention of the bot.
    * `:mentioned?` - whether it mentioned the bot. `false` unless set.
    * `:direct?` - whether it was sent to the bot directly, as a direct message. The channel's
      `:direct` agent answers it. `false` unless set.
  """

  @enforce_keys [:room, :id, :sender, :text]
  defstruct [
    :room,
    :thread,
    :parent,
    :parent_notice,
    :id,
    :sender,
    :text,
    mentioned?: false,
    direct?: false
  ]

  @type t() :: %__MODULE__{
          room: String.t(),
          thread: String.t() | nil,
          parent: String.t() | nil,
          parent_notice: map() | nil,
          id: String.t(),
          sender: Wardrik.Chat.Member.t(),
          text: String.t(),
          mentioned?: boolean(),
          direct?: boolean()
        }
end
