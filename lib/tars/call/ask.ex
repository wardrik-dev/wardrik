defmodule Tars.Call.Ask do
  @moduledoc """
  What something asked a person about a `Tars.Call` before it may go ahead.

  `:by` is the name of the `Tars.Hook` that asked, `:tool` where the call's
  own tool asked, or `:ledger` where the call began before its agent was lost.
  `:memo` is what the hook asked with, handed back to it once a person
  approves.
  """

  @enforce_keys [:by, :prompt]
  defstruct [:by, :prompt, :memo]

  @type t() :: %__MODULE__{by: String.t() | :tool | :ledger, prompt: String.t(), memo: term()}
end
