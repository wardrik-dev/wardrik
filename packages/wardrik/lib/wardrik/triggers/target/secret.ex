defmodule Wardrik.Triggers.Target.Secret do
  @moduledoc """
  What `c:Wardrik.Triggers.Target.resolve_secret/2` is asked for: the secret `name` held for
  `agent`. A webhook names it as `${NAME}`.

      %Wardrik.Triggers.Target.Secret{agent: "agt_triage", name: "GITHUB_WEBHOOK_SECRET"}
  """

  @enforce_keys [:agent, :name]
  defstruct [:agent, :name]

  @type t() :: %__MODULE__{agent: String.t(), name: String.t()}
end
