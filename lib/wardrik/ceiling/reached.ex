defmodule Wardrik.Ceiling.Reached do
  @moduledoc "What a model call waits on when its org's agents have spent a ceiling's limit together."

  defstruct interrupt: "ceiling_approval", message: nil, labels: []

  @type t() :: %__MODULE__{interrupt: String.t(), message: String.t(), labels: [String.t()]}
end
