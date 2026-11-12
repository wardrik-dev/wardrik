defmodule WardrikCore.ToolCall do
  @moduledoc "A tool call the model asked for, with the arguments the model wrote."

  @enforce_keys [:id, :name]
  defstruct [:id, :name, arguments: %{}]

  @type t() :: %__MODULE__{id: String.t(), name: String.t(), arguments: map()}

  @doc false
  @spec from_req_llm(ReqLLM.ToolCall.t()) :: t()
  def from_req_llm(%ReqLLM.ToolCall{} = call) do
    %__MODULE__{
      id: call.id,
      name: ReqLLM.ToolCall.name(call),
      arguments: ReqLLM.ToolCall.args_map(call) || %{}
    }
  end
end
