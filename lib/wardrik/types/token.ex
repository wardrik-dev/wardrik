defmodule Wardrik.Token do
  @moduledoc """
  An API token, never its secret: its `id`, its `name`, the `principal` it acts for, by id, its
  `statements`, the `policy` every agent it defines is held to, and when it `expires`.
  """

  use Wardrik.Type,
    schema: ["token"],
    fields: [
      id: "id",
      name: "name",
      principal: "principal.id",
      statements: {"statements", [Wardrik.Statement]},
      policy: "policy",
      expires: {"expires", :datetime},
      created_at: {"created_at", :datetime}
    ]
end

defmodule Wardrik.TokenIssued do
  @moduledoc "A token just made, and its `secret`, given this once: present it as `Authorization: Bearer <secret>`."

  use Wardrik.Type,
    schema: ["token_issued"],
    fields: [token: {"token", Wardrik.Token}, secret: "secret"]
end
