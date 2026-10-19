defmodule Wardrik.Test.Turn do
  @moduledoc """
  A turn of `Wardrik.Test.Runtime`: the `Wardrik.LLM.Turn` its
  `Wardrik.Test.Script`'s functions are handed, which they hand back done,
  waiting or failed. It is that turn in all else, so a test drives an agent
  through what an LLM turn comes to without a model.
  """

  @enforce_keys [:script, :turn]
  defstruct [:script, :turn]

  @type t() :: %__MODULE__{script: Wardrik.Test.Script.t(), turn: Wardrik.Turn.t()}

  @doc "The turn `script` makes of `turn`, as a checkpoint a script hands its journal is."
  @spec new(Wardrik.Test.Script.t(), Wardrik.Turn.t()) :: t()
  def new(%Wardrik.Test.Script{} = script, turn), do: %__MODULE__{script: script, turn: turn}

  defimpl Wardrik.Turn do
    alias Wardrik.Turn

    def run(test), do: applied(test, test.script.run, [])
    def resume(test, decisions), do: applied(test, test.script.resume, [decisions])
    def recover(test), do: applied(test, test.script.recover, [])
    def status(test), do: Turn.status(test.turn)
    def waiting(test), do: Turn.waiting(test.turn)
    def awaiting(test, ref, owner), do: Turn.awaiting(test.turn, ref, owner)
    def awaited(test), do: Turn.awaited(test.turn)
    def under(test, run), do: %{test | turn: Turn.under(test.turn, run)}
    def stale?(test, hooks), do: Turn.stale?(test.turn, hooks)
    def dump(test), do: %{test | turn: Turn.dump(test.turn)}
    def load(test, history), do: %{test | turn: Turn.load(test.turn, history)}

    defp applied(test, {module, function, args}, more),
      do: %{test | turn: apply(module, function, args ++ [test.turn | more])}
  end
end
