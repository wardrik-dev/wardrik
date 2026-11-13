defmodule Wardrik.Connecting do
  @moduledoc """
  What connecting an account answers.

    * `:provider` - its name.
    * `:connected` - whether the caller holds it already.
    * `:authorization` - where to sign in where it isn't held yet: `"url"`, and for a device
      sign-in the `"code"` to enter there.
  """

  use Wardrik.Type,
    schema: ["connecting"],
    fields: [provider: "provider", connected: "connected", authorization: "authorization"]
end
