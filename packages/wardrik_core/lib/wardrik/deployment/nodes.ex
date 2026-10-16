defmodule Wardrik.Deployment.Nodes do
  @moduledoc """
  The deployment's nodes, each with how many agents run on it, in the order
  `Wardrik.Deployment.nodes/0` gives them, and how many agents sleep, on
  none.
  """

  @enforce_keys [:nodes, :asleep]
  defstruct [:nodes, :asleep]

  @type t() :: %__MODULE__{
          nodes: [{node(), non_neg_integer()}],
          asleep: non_neg_integer()
        }
end
