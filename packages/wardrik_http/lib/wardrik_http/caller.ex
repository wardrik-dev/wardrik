defmodule WardrikHTTP.Caller do
  @moduledoc """
  Who made a request, as a `WardrikHTTP.Authenticator` answered it.

    * `:id` and `:name` - the credential presented, such as a token's id and
      name. The tools a worker offers are bound to it, and a call a worker
      answered names it.
    * `:principal` - the `Wardrik.Principal` the credential acts for, whom a
      decision is recorded as made by.
    * `:grant` - what it may do, a `Wardrik.Grant`.
    * `:ref` - the record a stream or a worker's socket holds while it runs,
      so revoking the credential ends them, as `WardrikHTTP.Access.hold/1`
      takes it; `nil` where there is none to hold.
  """

  @enforce_keys [:id, :name, :principal, :grant]
  defstruct [:id, :name, :principal, :grant, :ref]

  @type t() :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          principal: Wardrik.Principal.t(),
          grant: Wardrik.Grant.t(),
          ref: WardrikHTTP.Access.ref() | nil
        }
end
