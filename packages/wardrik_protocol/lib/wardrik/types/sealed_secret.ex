defmodule Wardrik.SealedSecret do
  @moduledoc """
  A secret an owner holds, without its value.

    * `:name` - its name, as `CRM_KEY`.
    * `:purpose` - what it's read for: `:api_key`, `:client_secret`, `:header` or
      `:signing_secret` for one the owner sealed, `:grant` for an account they connected,
      `:token` for a chat app's install, or `:secret` for one sealed with no purpose.
  """

  use Wardrik.Type,
    schema: ["secrets", "properties", "secrets", "items"],
    fields: [
      name: "name",
      purpose:
        {"purpose", [:api_key, :client_secret, :header, :signing_secret, :grant, :token, :secret]}
    ]
end
