defmodule Wardrik.Test.Calls do
  @moduledoc """
  Tool calls built and read the way `Wardrik.LLM.ToolRunner` builds and reads
  them, for a test that hands a tool its call directly.
  """

  alias Wardrik.Call

  @doc "An allowed call to the tool `name`, under `scope`, as a tool is handed it."
  @spec tool(String.t(), map(), Wardrik.Scope.t() | nil) :: Call.t()
  def tool(name, arguments \\ %{}, scope \\ nil) do
    %Call{
      id: "call_1",
      target: %Call.Tool{name: name, arguments: arguments},
      scope: scope,
      state: :allowed
    }
  end

  @doc """
  Hands `tool`, one `Wardrik.Tool.new!/1` built, a call with `arguments` under
  `scope`, and says what it came to, as `result/1` does.
  """
  @spec run(ReqLLM.Tool.t(), map(), Wardrik.Scope.t() | nil) :: term()
  def run(
        %ReqLLM.Tool{callback: {Wardrik.Tool, :invoke, [handler]}} = built,
        arguments,
        scope \\ nil
      ) do
    {:ok, input} = ReqLLM.Tool.validate_input(built, arguments)
    handler |> Wardrik.Tool.hand(tool(built.name, input, scope)) |> result()
  end

  @doc """
  What a call a tool handed back came to: its result where it was answered,
  or `{:park, prompt}` where it parked.
  """
  @spec result(Call.t()) :: term()
  def result(%Call{state: :done, result: result}), do: result
  def result(%Call{state: :waiting} = call), do: {:park, Call.prompt(call)}
end
