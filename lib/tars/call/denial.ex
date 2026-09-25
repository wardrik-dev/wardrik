defmodule Tars.Call.Denial do
  @moduledoc """
  Why a `Tars.Call` may not go ahead, and who said so: the name of the
  `Tars.Hook` that refused it, or `:person` for one a person refused.
  """

  @enforce_keys [:by, :reason]
  defstruct [:by, :reason]

  @type t() :: %__MODULE__{by: String.t() | :person, reason: String.t()}
end
