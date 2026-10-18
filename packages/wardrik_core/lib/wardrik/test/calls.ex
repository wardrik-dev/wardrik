defmodule Wardrik.Test.Calls do
  @moduledoc """
  Tool calls built and read the way `Wardrik.LLM.ToolRunner` builds and reads
  them, for a test that hands a host's `Wardrik.Credentials` its call
  directly. A test that runs a call the way a turn does uses
  `Wardrik.Test.call/4`, and one that hands a tool its arguments uses
  `Wardrik.Test.context/2`.
  """

  alias Wardrik.Call

  @doc "An allowed call to the tool `name`, under `run`, as a tool is handed it."
  @spec tool(String.t(), map(), Wardrik.Run.t() | nil) :: Call.t()
  def tool(name, arguments \\ %{}, run \\ nil) do
    %Call{
      id: "call_1",
      target: %Call.Tool{name: name, arguments: arguments},
      run: run,
      state: :allowed
    }
  end

  @doc """
  What a call a tool handed back came to: its result where it was answered,
  or `{:park, prompt}` where it parked.
  """
  @spec result(Call.t()) :: term()
  def result(%Call{state: :done, result: result}), do: result
  def result(%Call{state: :waiting} = call), do: {:park, Call.prompt(call)}
end
