defmodule WardrikCore.Resume do
  @moduledoc """
  What a parked step sees when it runs again: why it parked, and the `input` and `metadata` given
  to `WardrikCore.resume/3`.
  """

  @enforce_keys [:reason, :input]
  defstruct [:reason, :input, metadata: %{}]

  @type t() :: %__MODULE__{reason: term(), input: term(), metadata: map()}
end
