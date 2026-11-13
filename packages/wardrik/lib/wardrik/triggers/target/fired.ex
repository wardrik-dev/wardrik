defmodule Wardrik.Triggers.Target.Fired do
  @moduledoc """
  What `c:Wardrik.Triggers.Target.fired/2` is told: how a run of `agent`'s `trigger` went.
  `last` is `true` when the trigger won't run again, as an `at` after its run.

      %Wardrik.Triggers.Target.Fired{agent: "agt_triage", trigger: "daily", status: :asked}
  """

  @enforce_keys [:agent, :trigger, :status]
  defstruct [:agent, :trigger, :status, last: false]

  @type t() :: %__MODULE__{
          agent: String.t(),
          trigger: String.t(),
          status: Wardrik.Triggers.Trigger.status(),
          last: boolean()
        }
end
