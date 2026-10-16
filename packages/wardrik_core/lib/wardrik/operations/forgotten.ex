defmodule Wardrik.Operations.Forgotten do
  @moduledoc """
  What a forget did: the agents it removed, those it kept, each with why, as
  one an agent file declares, and those it could not remove, each with why.
  """

  alias Wardrik.AgentID

  @enforce_keys [:agents, :kept, :failed]
  defstruct [:agents, :kept, :failed]

  @type t() :: %__MODULE__{
          agents: [AgentID.t()],
          kept: [{AgentID.t(), String.t()}],
          failed: [{AgentID.t(), String.t()}]
        }
end
