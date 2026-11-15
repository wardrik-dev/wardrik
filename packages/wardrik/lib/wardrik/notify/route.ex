defmodule Wardrik.Notify.Route do
  @moduledoc """
  Where an agent's notices go (`:to`), which kinds are sent (`:on`), and what judges a finished
  one (`:judge`). Read from a definition with `Wardrik.Notify.route/1`.
  """

  @enforce_keys [:to, :on]
  defstruct [:to, :on, :judge]

  @typedoc "A judge's question, the probability that sends, and the model that answers."
  @type judge() :: %{question: String.t(), send: float(), model: String.t()}

  @type t() :: %__MODULE__{
          to: [String.t()],
          on: [Wardrik.Notice.kind()],
          judge: judge() | nil
        }
end
