defmodule Wardrik.Call.Ask do
  @moduledoc """
  What something asked a person about a `Wardrik.Call` before it may go ahead.

  `:by` is the name of the `Wardrik.Hook` that asked, `:tool` where the call's
  own tool asked, or `:ledger` where the call began before its agent was lost.
  `:memo` is what the hook asked with, handed back to it once a person
  approves. `:link` is where a tool that asked sends the person to authorize
  it, kept apart from the prompt so it is shown only where the person
  answering is; see `Wardrik.Call.park/3`.
  """

  @enforce_keys [:by, :prompt]
  defstruct [:by, :prompt, :memo, :link]

  @typedoc "Where a person authorizes: a URL, and a code to enter there where one is needed."
  @type link() :: %{url: String.t(), code: String.t() | nil}

  @type t() :: %__MODULE__{
          by: String.t() | :tool | :ledger,
          prompt: String.t(),
          memo: term(),
          link: link() | nil
        }
end
