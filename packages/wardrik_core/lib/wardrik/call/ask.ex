defmodule Wardrik.Call.Ask do
  @moduledoc """
  What something asked a person about a `Wardrik.Call` before it may go ahead.

  `:by` is the name of the `Wardrik.Hook` that asked, `:tool` where the call's
  own tool asked, or a model call's tries were spent, or `:doubt` where the
  call may already have done what it does: it began before its agent was
  lost, or its tool could not say how it ended. `:memo` is what the hook asked with, handed back to it once a person
  approves. `:link` is where a tool that asked sends the person to authorize
  it, kept apart from the prompt so it is shown only where the person
  answering is; see `Wardrik.Call.park/3`. `:credential` is the credential
  the runtime parked the call to resolve, named, and whose it will be, so
  the call carries on by itself once it can be; see
  `Wardrik.Credential.available/3`.
  """

  @enforce_keys [:by, :prompt]
  defstruct [:by, :prompt, :memo, :link, :credential]

  @typedoc "Where a person authorizes: a URL, and a code to enter there where one is needed."
  @type link() :: %{url: String.t(), code: String.t() | nil}

  @typedoc "A credential a call waits on: its name, and whose it will be."
  @type credential() :: %{ref: Wardrik.Credential.ref(), owner: Wardrik.Credential.owner()}

  @type t() :: %__MODULE__{
          by: String.t() | :tool | :doubt,
          prompt: String.t(),
          memo: term(),
          link: link() | nil,
          credential: credential() | nil
        }
end
