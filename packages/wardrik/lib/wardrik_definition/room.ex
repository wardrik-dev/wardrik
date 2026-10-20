defmodule WardrikDefinition.Room do
  @moduledoc """
  A room in a channel a definition's `notify` routes to, written
  `<channel>:<room>`, as `slack:#updates`: the channel by its name, and
  the room as the channel names it. It reads as it is written.
  """

  @enforce_keys [:channel, :room]
  defstruct [:channel, :room]

  @type t() :: %__MODULE__{channel: String.t(), room: String.t()}

  defimpl String.Chars do
    def to_string(%{channel: channel, room: room}), do: channel <> ":" <> room
  end
end
