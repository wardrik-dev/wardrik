defmodule WardrikPolicy.Rule do
  @moduledoc """
  One thing a policy says: that the tools a pattern names may run, must ask a
  person first, or may not run, and what it tells them. An allow with
  `after_outside` still holds once the run has read content from outside.
  """

  alias WardrikPolicy.Pattern

  @enforce_keys [:effect, :pattern]
  defstruct [:effect, :pattern, :message, after_outside: false]

  @typedoc "What a rule does to a call it matches."
  @type effect() :: :allow | :ask | :deny

  @type t() :: %__MODULE__{
          effect: effect(),
          pattern: Pattern.t(),
          message: String.t() | nil,
          after_outside: boolean()
        }

  @doc "Whether the rule speaks for the whole of a call to the tool the agent knows as `name`."
  @spec match?(t(), String.t()) :: boolean()
  def match?(%__MODULE__{pattern: pattern}, name), do: Pattern.match?(pattern, name)

  @doc "Whether the rule speaks for `subject` of a call to the tool the agent knows as `name`."
  @spec match?(t(), String.t(), String.t()) :: boolean()
  def match?(%__MODULE__{pattern: pattern}, name, subject),
    do: Pattern.match?(pattern, name, subject)
end
