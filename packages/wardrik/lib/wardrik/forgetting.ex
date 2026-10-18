defmodule Wardrik.Forgetting do
  @moduledoc """
  What forgetting would do, as `Wardrik.agent_forget_preview/2` and
  `Wardrik.agents_forget_preview/2` answer it: the agents it removes, with
  everything each had, and those the host keeps, each with why, as one an
  agent file declares.
  """

  @enforce_keys [:agents, :kept]
  defstruct [:agents, :kept]

  @type t() :: %__MODULE__{
          agents: [Wardrik.AgentID.t()],
          kept: [{Wardrik.AgentID.t(), String.t()}]
        }
end
