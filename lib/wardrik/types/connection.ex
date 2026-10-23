defmodule Wardrik.Connection do
  @moduledoc "An account an owner is offered, by its `provider`'s name, and whether they hold it."

  use Wardrik.Type, schema: ["connection"], fields: [provider: "provider", connected: "connected"]
end

defmodule Wardrik.Connecting do
  @moduledoc """
  Connecting an account: whether the owner holds it already, or the `authorization` where they
  sign in to it.
  """

  use Wardrik.Type,
    schema: ["connecting"],
    fields: [
      provider: "provider",
      connected: "connected",
      authorization: {"authorization", Wardrik.Authorization}
    ]
end
