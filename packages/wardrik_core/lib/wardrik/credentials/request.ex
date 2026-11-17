defmodule Wardrik.Credentials.Request do
  @moduledoc """
  What a `Wardrik.Credentials` module is asked for: the credential `name`, for `principal`.

      %Wardrik.Credentials.Request{
        name: "github",
        principal: %Wardrik.Principal{id: "user:maria"},
        agent: "triage",
        call: "call_1"
      }

    * `principal` is `nil` when the turn acts for no one.
    * `agent` is the agent whose tool asks.
    * `call` is the tool call that asks, or `nil` outside one.
  """

  @enforce_keys [:name, :principal]
  defstruct [:name, :principal, :agent, :call]

  @type t() :: %__MODULE__{
          name: String.t(),
          principal: Wardrik.Principal.t() | nil,
          agent: String.t() | nil,
          call: String.t() | nil
        }
end
