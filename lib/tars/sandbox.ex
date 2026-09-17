defmodule Tars.Sandbox do
  @moduledoc """
  Runs code an agent wrote, under limits, with no way out to the node.

  Core ships no sandbox. A package implements this behaviour over a VM and
  gives an agent a tool that reaches it; `TarsLua` does it with a Lua 5.3 VM.

      Tars.Sandbox.run(TarsLua.Sandbox, "return 2 + 2", Tars.Sandbox.Limits.new())
      #=> {:ok, 4}

  `run/3` is the way in. It asks the sandbox whether the code can run at all,
  then evaluates it in a task of its own under `t:Tars.Sandbox.Limits.t/0`,
  and returns the value the code produced as data a turn can put in front of a
  model.

  A sandbox implements the language and nothing else. `c:evaluate/2` runs in
  the process `Tars.Sandbox.Runner` has already bounded, so an implementation
  evaluates in place rather than spawning, and reports what the VM enforces
  for itself — a step budget spent, a stack too deep.

  Failure is a sentence, because the model is what reads it.
  """

  alias Tars.Sandbox.Limits
  alias Tars.Sandbox.Runner

  @typedoc "What an evaluation produced, or why it produced nothing."
  @type result() :: {:ok, term()} | {:error, String.t()}

  @doc "Whether this code can run, without running it."
  @callback check(String.t()) :: :ok | {:error, String.t()}

  @doc "Runs `code` in the caller's process and returns the value it produced."
  @callback evaluate(String.t(), Limits.t()) :: result()

  @doc "Checks `code`, then runs it under `limits`."
  @spec run(module(), String.t(), Limits.t()) :: result()
  def run(sandbox, code, %Limits{} = limits) when is_atom(sandbox) do
    with :ok <- sandbox.check(code) do
      Runner.run(fn -> sandbox.evaluate(code, limits) end, limits)
    end
  end
end
