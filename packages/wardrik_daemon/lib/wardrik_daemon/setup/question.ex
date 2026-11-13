defmodule WardrikDaemon.Setup.Question do
  @moduledoc """
  A yes or no question a setup step asks.

    * `:key` - required. Names it for `--set` and `--answers`, as `coding.claude`.
    * `:label` - required. What's asked, as `Found Claude Code. Let agents use it?`.
    * `:default` - the answer on Enter. `true` unless set.

  Without a terminal, the answer is the one given, or else `--yes`.
  """

  @enforce_keys [:key, :label]
  defstruct [:key, :label, default: true]

  @type t() :: %__MODULE__{key: String.t(), label: String.t(), default: boolean()}

  @doc "Returns `given` as an answer to `question`, or why it isn't one."
  @spec cast(t(), term()) :: {:ok, boolean()} | {:error, String.t()}
  def cast(%__MODULE__{}, given) when is_boolean(given), do: {:ok, given}

  def cast(%__MODULE__{key: key}, given) do
    case String.downcase(to_string(given)) do
      yes when yes in ~w(true yes y) -> {:ok, true}
      no when no in ~w(false no n) -> {:ok, false}
      _other -> {:error, "#{key} is true or false, not #{inspect(given)}."}
    end
  end
end
