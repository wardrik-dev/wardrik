defmodule WardrikGateway.Unavailable do
  @moduledoc """
  Returned when no model could take a call within the gateway's `:wait`: every breaker was open,
  or every provider was at its limit. `WardrikCore.Retry` then applies.
  """

  defexception [:models]

  @type t() :: %__MODULE__{models: [String.t()]}

  @impl Exception
  def message(%__MODULE__{models: models}),
    do: "No model could take the call in time: #{Enum.join(models, ", ")}."
end
