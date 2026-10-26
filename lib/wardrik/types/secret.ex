defmodule Wardrik.Secret do
  @moduledoc "A secret an owner holds, by its `name`: one they sealed, `:secret`, or an account they connected, `:grant`."

  use Wardrik.Type,
    schema: ["secrets", "properties", "secrets", "items"],
    fields: [name: "name", kind: {"kind", [:secret, :grant]}]
end
