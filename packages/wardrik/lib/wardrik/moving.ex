defmodule Wardrik.Moving do
  @moduledoc """
  What moving an agent would do, as `Wardrik.agent_move_preview/3` answers
  it: the agent, the node it runs on, or `:asleep`, the node it goes to, and
  what it is doing, which a move interrupts. An agent on that node already
  stays as it is.
  """

  @enforce_keys [:agent, :from, :to, :status]
  defstruct [:agent, :from, :to, :status]

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentID.t(),
          from: node() | :asleep,
          to: node(),
          status: Wardrik.Fleet.Member.status()
        }
end
