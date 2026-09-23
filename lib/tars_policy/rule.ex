defmodule TarsPolicy.Rule do
  @moduledoc """
  One thing a policy says: that the tools a pattern names may run, must ask a
  person first, or may not run, and what it tells them.
  """

  alias TarsPolicy.Pattern

  @enforce_keys [:effect, :pattern]
  defstruct [:effect, :pattern, :message]

  @typedoc "What a rule does to a call it matches."
  @type effect() :: :allow | :ask | :deny

  @type t() :: %__MODULE__{effect: effect(), pattern: Pattern.t(), message: String.t() | nil}

  @doc "Whether the rule speaks for the tool the agent knows as `name`."
  @spec match?(t(), String.t()) :: boolean()
  def match?(%__MODULE__{pattern: pattern}, name), do: Pattern.match?(pattern, name)
end
