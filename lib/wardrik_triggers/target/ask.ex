defmodule WardrikTriggers.Target.Ask do
  @moduledoc """
  What `c:WardrikTriggers.Target.ask/2` asks: that `agent` be asked `prompt`, by `trigger`.

      %WardrikTriggers.Target.Ask{
        agent: "acme/triage",
        prompt: "Write the digest.",
        trigger: "daily",
        overlap: :skip,
        labels: []
      }

  ## Fields

    * `:agent` - the agent's ID.
    * `:prompt` - what to ask it.
    * `:trigger` - the trigger's name.
    * `:overlap` - `:skip` to ask nothing, and answer `:busy`, while the agent is busy. `:queue`
      to ask anyway.
    * `:labels` - `["outside"]` when the prompt holds feed entries or a webhook body. `[]`
      otherwise.
  """

  @enforce_keys [:agent, :prompt, :trigger]
  defstruct [:agent, :prompt, :trigger, overlap: :skip, labels: []]

  @type t() :: %__MODULE__{
          agent: String.t(),
          prompt: String.t(),
          trigger: String.t(),
          overlap: :skip | :queue,
          labels: [String.t()]
        }
end
