defmodule WardrikChannel.Offer do
  @moduledoc """
  An agent a channel offers in its rooms, with what it says it is for, which
  the channel shows whoever chooses it.
  """

  @enforce_keys [:agent]
  defstruct [:agent, :description]

  @type t() :: %__MODULE__{agent: Wardrik.AgentID.t(), description: String.t() | nil}
end
