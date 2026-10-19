defmodule Wardrik.Call.Tool do
  @moduledoc """
  The tool a `Wardrik.Call` goes to, and what it is asked: the tool's name as the
  agent knows it, and the arguments the model gave: decoded, or as it wrote
  them where they did not read as a JSON object.

  What the tool declares about a call, `Wardrik.Tool.declared/2` writes here
  before any hook is asked, so a hook reads it as data:

    * `:gated` - the call waits on a person unless a hook allows it by name;
      see `Wardrik.Tool.Annotations`
    * `:subjects` - what the call acts on, as its tool names it from the
      arguments; see `c:Wardrik.Tool.subjects/2`
  """

  @enforce_keys [:name]
  defstruct [:name, arguments: %{}, gated: false, subjects: []]

  @type t() :: %__MODULE__{
          name: String.t(),
          arguments: map() | String.t(),
          gated: boolean(),
          subjects: [String.t()]
        }
end
