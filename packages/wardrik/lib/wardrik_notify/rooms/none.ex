defmodule WardrikNotify.Rooms.None do
  @moduledoc """
  The `WardrikNotify.Rooms` of a host that runs no channels: it posts in
  no room, and says so. A host that registers no `:rooms` has it.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl WardrikNotify.Rooms, for: WardrikNotify.Rooms.None do
  def post(_none, _room, _notice, _opts), do: {:skip, "but this host runs no channels"}
end
