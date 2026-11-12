defmodule Wardrik.Triggers.Target.Ask do
  @moduledoc """
  What `c:Wardrik.Triggers.Target.ask/2` asks: that `agent` be asked `prompt`, by `trigger`.

      %Wardrik.Triggers.Target.Ask{
        agent: "agt_triage",
        prompt: "Write the digest.",
        trigger: "daily",
        overlap: :settle,
        labels: []
      }

  ## Fields

    * `:agent` - the agent's ID.
    * `:prompt` - what to ask it.
    * `:trigger` - the trigger's name.
    * `:overlap` - `:skip` to ask nothing, and answer `:busy`, while the agent is busy. `:queue`
      to ask anyway. `:settle` to cancel a turn waiting on an answer nobody gave, then ask, and
      to answer `:busy` while the agent is busy otherwise.
    * `:labels` - `["outside"]` when the prompt holds feed entries or a webhook body. `[]`
      otherwise.
  """

  @enforce_keys [:agent, :prompt, :trigger]
  defstruct [:agent, :prompt, :trigger, overlap: :settle, labels: []]

  @type t() :: %__MODULE__{
          agent: String.t(),
          prompt: String.t(),
          trigger: String.t(),
          overlap: :skip | :queue | :settle,
          labels: [String.t()]
        }
end
