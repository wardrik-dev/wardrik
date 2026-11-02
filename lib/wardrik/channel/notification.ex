defmodule Wardrik.Channel.Notification do
  @moduledoc """
  What `c:Wardrik.Channel.notify/2` posts: `notice`, in `room` of `workspace`.

      %Wardrik.Channel.Notification{workspace: "T0123", room: "#ops", notice: notice}

  `workspace` is the one the agent's resolver gives for the channel. See `Wardrik.Resolved`.
  """

  @enforce_keys [:workspace, :room, :notice]
  defstruct [:workspace, :room, :notice]

  @type t() :: %__MODULE__{workspace: String.t(), room: String.t(), notice: Wardrik.Notice.t()}
end
