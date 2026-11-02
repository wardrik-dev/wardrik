defmodule WardrikTriggers.Target.Secret do
  @moduledoc """
  What `c:WardrikTriggers.Target.resolve_secret/2` is asked for: the secret `name` held for
  `agent`. A webhook names it as `${NAME}`.

      %WardrikTriggers.Target.Secret{agent: "acme/triage", name: "GITHUB_WEBHOOK_SECRET"}
  """

  @enforce_keys [:agent, :name]
  defstruct [:agent, :name]

  @type t() :: %__MODULE__{agent: String.t(), name: String.t()}
end
