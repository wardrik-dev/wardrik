defmodule WardrikChannel.Offer do
  @moduledoc "An agent that may answer in a channel's rooms, with its name and description."

  @enforce_keys [:agent]
  defstruct [:agent, :name, :description]

  @type t() :: %__MODULE__{
          agent: String.t(),
          name: String.t() | nil,
          description: String.t() | nil
        }
end
