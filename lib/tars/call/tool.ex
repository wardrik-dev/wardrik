defmodule Tars.Call.Tool do
  @moduledoc """
  The tool a `Tars.Call` goes to, and what it is asked: the tool's name as the
  agent knows it, and the arguments the model gave.
  """

  @enforce_keys [:name]
  defstruct [:name, arguments: %{}]

  @type t() :: %__MODULE__{name: String.t(), arguments: map()}
end
