defmodule Wardrik.Forgotten do
  @moduledoc """
  The result of forgetting many agents. `forgotten` lists the IDs forgotten. `kept` and `failed`
  list `{id, why}` pairs.
  """

  use Wardrik.Type,
    schema: ["forgotten"],
    fields: [forgotten: "forgotten", kept: {"kept", :reasons}, failed: {"failed", :reasons}]
end
