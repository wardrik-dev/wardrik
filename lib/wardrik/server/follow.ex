defmodule Wardrik.Server.Follow do
  @moduledoc """
  What `c:Wardrik.Server.follow/2` sends and follows: `input` to `agent`, or to its
  `conversation`, in `scope`.

      %Wardrik.Server.Follow{scope: scope, agent: "agt_01JF8X5RQ2", input: "What's on fire?"}
  """

  @enforce_keys [:scope, :agent, :input]
  defstruct [:scope, :agent, :input, conversation: nil]

  @type t() :: %__MODULE__{
          scope: Wardrik.Scope.t(),
          agent: String.t() | struct(),
          conversation: String.t() | nil,
          input: term()
        }
end
