defmodule Wardrik.Forgotten do
  @moduledoc """
  What forgetting many agents did: the IDs `forgotten`, and those `kept` and `failed`, each as
  `{id, why}`.
  """

  use Wardrik.Type,
    schema: ["forgotten"],
    fields: [forgotten: "forgotten", kept: {"kept", :reasons}, failed: {"failed", :reasons}]
end
