defmodule WardrikChannel.Room do
  @moduledoc """
  A room of a workspace a channel is installed in, such as a Slack
  channel: the `WardrikChannel.Workspace` it is in, and its id there, as
  the channel names it. `WardrikChannel.Rooms` and `WardrikChannel.Replies`
  act on one.
  """

  alias WardrikChannel.Workspace

  @enforce_keys [:workspace, :id]
  defstruct [:workspace, :id]

  @type t() :: %__MODULE__{workspace: Workspace.t(), id: String.t()}

  @doc "The room `id` of `workspace`."
  @spec new(Workspace.t(), String.t()) :: t()
  def new(%Workspace{} = workspace, id) when is_binary(id),
    do: %__MODULE__{workspace: workspace, id: id}

  @doc "What the room is kept under: its channel, its workspace and its id."
  @spec key(t()) :: String.t()
  def key(%__MODULE__{workspace: %Workspace{installation: installation}, id: id}),
    do: Enum.join([installation.channel, installation.workspace, id], "/")
end
