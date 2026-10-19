defmodule Wardrik.Test.Runtime do
  @moduledoc """
  The `Wardrik.Runtime` of an agent whose config is a `Wardrik.Test.Script`:
  each turn is a `Wardrik.Test.Turn`, which does what the script says. Its
  key is `test`, and `Wardrik.Test.host/1` runs it beside
  `Wardrik.LLM.Runtime`. A definition never names it, since a script is a
  test's own.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl Wardrik.Runtime, for: Wardrik.Test.Runtime do
  alias Wardrik.Conversation

  def key(_runtime), do: "test"

  def read(_runtime, _fields, _context), do: {:error, "a test gives its agents their scripts"}

  def turn(_runtime, run, opts) do
    context = Conversation.append(Keyword.fetch!(opts, :history), Keyword.fetch!(opts, :asked))

    Wardrik.Test.Turn.new(run.config, %Wardrik.LLM.Turn{
      run: run,
      context: context,
      labels: run.labels
    })
  end
end
