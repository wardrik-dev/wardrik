defmodule WardrikChannel.Binding do
  @moduledoc """
  A room bound to the agent that answers in it, and when it answers: when
  mentioned, `:mentions`, or to every message, `:everything`. It names the
  room by its channel, its workspace and its id, as `WardrikChannel.Rooms`
  keeps it. See `WardrikChannel.Rooms`.
  """

  @enforce_keys [:channel, :workspace, :room, :agent]
  defstruct [:channel, :workspace, :room, :agent, answers: :mentions]

  @typedoc "When the agent answers in a room."
  @type answers() :: :mentions | :everything

  @type t() :: %__MODULE__{
          channel: String.t(),
          workspace: String.t(),
          room: String.t(),
          agent: Wardrik.AgentID.t(),
          answers: answers()
        }
end
