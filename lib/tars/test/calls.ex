defmodule Tars.Test.Calls do
  @moduledoc """
  Tool calls built and read the way `Tars.LLM.ToolRunner` builds and reads
  them, for a test that hands a tool its call directly.
  """

  alias Tars.Call

  @doc "An allowed call to the tool `name`, under `scope`, as a tool is handed it."
  @spec tool(String.t(), map(), Tars.Scope.t() | nil) :: Call.t()
  def tool(name, arguments \\ %{}, scope \\ nil) do
    %Call{
      id: "call_1",
      target: %Call.Tool{name: name, arguments: arguments},
      scope: scope,
      state: :allowed
    }
  end

  @doc """
  Hands `tool`, one `Tars.Tool.new!/1` built, a call with `arguments` under
  `scope`, and says what it came to, as `result/1` does.
  """
  @spec run(ReqLLM.Tool.t(), map(), Tars.Scope.t() | nil) :: term()
  def run(
        %ReqLLM.Tool{callback: {Tars.Tool, :invoke, [handler]}} = built,
        arguments,
        scope \\ nil
      ) do
    {:ok, input} = ReqLLM.Tool.validate_input(built, arguments)
    handler |> Tars.Tool.hand(tool(built.name, input, scope)) |> result()
  end

  @doc """
  What a call a tool handed back came to: its result where it was answered,
  or `{:park, prompt}` where it parked.
  """
  @spec result(Call.t()) :: term()
  def result(%Call{state: :done, result: result}), do: result
  def result(%Call{state: :waiting} = call), do: {:park, Call.prompt(call)}
end
