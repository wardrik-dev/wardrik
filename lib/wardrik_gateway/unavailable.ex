defmodule WardrikGateway.Unavailable do
  @moduledoc """
  A model call no model could take within the gateway's `:wait`: each breaker stayed open, or each
  provider stayed at its limit. The agent's retries take it from here.
  """

  defexception [:models]

  @type t() :: %__MODULE__{models: [String.t()]}

  @impl Exception
  def message(%__MODULE__{models: models}),
    do: "No model could take the call in time: #{Enum.join(models, ", ")}."
end
