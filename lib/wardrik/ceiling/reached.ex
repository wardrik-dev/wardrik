defmodule Wardrik.Ceiling.Reached do
  @moduledoc "The interrupt a model call waits on once its org's agents reach a ceiling's limit."

  defstruct interrupt: "ceiling_approval", message: nil, labels: []

  @type t() :: %__MODULE__{interrupt: String.t(), message: String.t(), labels: [String.t()]}
end
