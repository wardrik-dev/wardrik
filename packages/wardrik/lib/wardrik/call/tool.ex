defmodule Wardrik.Call.Tool do
  @moduledoc """
  The tool a `Wardrik.Call` goes to, and what it is asked: the tool's name as the
  agent knows it, and the arguments the model gave.

  What the tool declares about a call, `Wardrik.LLM.ToolRunner` writes here
  before any hook is asked, so a hook reads it as data:

    * `:gated` - the call waits on a person unless a hook allows it by name;
      see `c:Wardrik.Tool.gated?/1`
    * `:subjects` - what the call acts on, as its tool names it from the
      arguments; see `c:Wardrik.Tool.subjects/2`
  """

  @enforce_keys [:name]
  defstruct [:name, arguments: %{}, gated: false, subjects: []]

  @type t() :: %__MODULE__{
          name: String.t(),
          arguments: map(),
          gated: boolean(),
          subjects: [String.t()]
        }
end
