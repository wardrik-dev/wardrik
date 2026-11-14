defmodule Wardrik.Principal do
  @moduledoc """
  Someone or something that can act, such as a person or a service.

      %Wardrik.Principal{id: "user:maria", attributes: %{team: "billing"}}

    * The agent's own comes from `WardrikCore.start_agent/2`'s `:principal`.
    * A message's sender comes from `WardrikCore.ask/3`. The turn acts for them.
    * `id` and `attributes` are your app's. Wardrik never reads them.
  """

  @enforce_keys [:id]
  defstruct [:id, attributes: %{}]

  @type t() :: %__MODULE__{id: String.t(), attributes: map()}
end
