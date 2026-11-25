defmodule WardrikDaemon.Setup.Choice do
  @moduledoc """
  A question a setup step asks with one answer out of several.

    * `:key` - required. Names it for `--set` and `--answers`, as `approvals`.
    * `:label` - required. What's asked.
    * `:options` - required. Each answer and what it means, as `{"balanced", "Balanced: ..."}`.
    * `:default` - required. The answer on Enter, and without a terminal where none is given.
  """

  @behaviour WardrikDaemon.Setup.Ask

  @enforce_keys [:key, :label, :options, :default]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          key: String.t(),
          label: String.t(),
          options: [{String.t(), String.t()}],
          default: String.t()
        }

  @doc "Returns `given` as an answer to `choice`, or why it isn't one."
  @impl WardrikDaemon.Setup.Ask
  @spec cast(t(), term()) :: {:ok, String.t()} | {:error, String.t()}
  def cast(%__MODULE__{key: key, options: options}, given) do
    answer = to_string(given)
    values = Enum.map(options, &elem(&1, 0))

    if answer in values,
      do: {:ok, answer},
      else: {:error, "#{key} is one of #{Enum.join(values, ", ")}, not #{inspect(given)}."}
  end

  @impl WardrikDaemon.Setup.Ask
  def ask_in_terminal(%__MODULE__{options: options, default: default} = choice) do
    {preferred, rest} = Enum.split_with(options, &(elem(&1, 0) == default))

    {value, _label} =
      Owl.IO.select(preferred ++ rest, label: choice.label, render_as: &elem(&1, 1))

    value
  end

  @impl WardrikDaemon.Setup.Ask
  def answer_unattended(%__MODULE__{default: default}, _flags), do: default
end
