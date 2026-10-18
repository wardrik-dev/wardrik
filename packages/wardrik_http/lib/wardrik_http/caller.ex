defmodule WardrikHTTP.Caller do
  @moduledoc """
  Who made a request, as a `WardrikHTTP.Authenticator` answered it.

    * `:id` and `:name` - the credential presented, such as a token's id and
      name. The tools a worker offers are bound to it, and a call a worker
      answered names it.
    * `:token` - the `Wardrik.Token` it acts with: whom a change is recorded
      as made by, and what it may do.
    * `:ref` - the record a stream or a worker's socket holds while it runs,
      so revoking the credential ends them, as `WardrikHTTP.Access.hold/2`
      takes it; `nil` where there is none to hold.
  """

  @enforce_keys [:id, :name, :token]
  defstruct [:id, :name, :token, :ref]

  @type t() :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          token: Wardrik.Token.t(),
          ref: WardrikHTTP.Access.ref() | nil
        }
end
