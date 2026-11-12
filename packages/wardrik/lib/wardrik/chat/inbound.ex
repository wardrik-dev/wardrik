defmodule WardrikChannel.Inbound do
  @moduledoc """
  A message someone posted in a room. Adapters pass it to `WardrikChannel.received/2`.

    * `:room` - the room it was posted in.
    * `:thread` - the thread it replies in, or `nil` if it starts one.
    * `:id` - unique in its room. A message passed twice is answered once.
    * `:sender` - a `WardrikChannel.Member`.
    * `:text` - the text, without any mention of the bot.
    * `:mentioned?` - whether it mentioned the bot. `false` unless set.
  """

  @enforce_keys [:room, :id, :sender, :text]
  defstruct [:room, :thread, :id, :sender, :text, mentioned?: false]

  @type t() :: %__MODULE__{
          room: String.t(),
          thread: String.t() | nil,
          id: String.t(),
          sender: WardrikChannel.Member.t(),
          text: String.t(),
          mentioned?: boolean()
        }
end
