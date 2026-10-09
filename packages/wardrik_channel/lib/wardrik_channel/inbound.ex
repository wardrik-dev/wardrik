defmodule WardrikChannel.Inbound do
  @moduledoc """
  A message someone posted in a room, as an adapter hands it to
  `WardrikChannel.received/2`.

    * `:channel` - the channel's name
    * `:room` - the room it was posted in, as the channel names it
    * `:thread` - the thread it replies in, or `nil` for a message posted in
      the room itself, which starts a thread of its own
    * `:id` - the message's id in the channel, unique in its room; the
      agent is asked under it, so a message handed over twice is answered
      once
    * `:sender` - who posted it, as a `Wardrik.Principal`
    * `:text` - what it says, with any mention of the bot taken out
    * `:mentioned?` - whether it mentions the bot
  """

  @enforce_keys [:channel, :room, :id, :sender, :text]
  defstruct [:channel, :room, :thread, :id, :sender, :text, mentioned?: false]

  @type t() :: %__MODULE__{
          channel: String.t(),
          room: String.t(),
          thread: String.t() | nil,
          id: String.t(),
          sender: Wardrik.Principal.t(),
          text: String.t(),
          mentioned?: boolean()
        }
end
