defmodule WardrikChannel.Place do
  @moduledoc """
  A room of a workspace a channel is installed in: the
  `WardrikChannel.Workspace` it is in, and its id there, as the channel
  names it. `WardrikChannel.Rooms` and `WardrikChannel.Replies` act on one.
  """

  alias WardrikChannel.Workspace

  @enforce_keys [:workspace, :room]
  defstruct [:workspace, :room]

  @type t() :: %__MODULE__{workspace: Workspace.t(), room: String.t()}

  @doc "The room `room` of `workspace`."
  @spec new(Workspace.t(), String.t()) :: t()
  def new(%Workspace{} = workspace, room) when is_binary(room),
    do: %__MODULE__{workspace: workspace, room: room}

  @doc "What the place is kept under: its channel, its workspace and its room."
  @spec key(t()) :: String.t()
  def key(%__MODULE__{workspace: %Workspace{installation: installation}, room: room}),
    do: Enum.join([installation.channel, installation.workspace, room], "/")
end
