defmodule Wardrik.LLM.Attempt do
  @moduledoc """
  One try of a model call that failed: the model it went to, why it failed,
  and whether the provider had begun to answer.

  A request asked again carries the tries before it, newest first, as its
  `attempts`, so the `Wardrik.LLM.Retry` deciding whether to ask again and the
  `Wardrik.LLM.Dispatch` admitting the next try both see what happened, and a
  dispatch can send the next try to another model.
  """

  @enforce_keys [:model_spec, :reason, :answered?]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          model_spec: term(),
          reason: term(),
          answered?: boolean()
        }
end
