defmodule Wardrik.Triggers.Target.Fired do
  @moduledoc """
  What `c:Wardrik.Triggers.Target.fired/2` is told: how a run of `agent`'s `trigger` went.

      %Wardrik.Triggers.Target.Fired{agent: "agt_triage", trigger: "daily", status: :asked}
  """

  @enforce_keys [:agent, :trigger, :status]
  defstruct [:agent, :trigger, :status]

  @type t() :: %__MODULE__{
          agent: String.t(),
          trigger: String.t(),
          status: Wardrik.Triggers.Trigger.status()
        }
end
