defmodule WardrikCore.ToolCall do
  @moduledoc "A tool call the model asked for, with the arguments the model wrote."

  @behaviour WardrikCore.Format

  alias WardrikCore.Stored.Term

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

  @impl WardrikCore.Format
  def type, do: "tool_call"

  @impl WardrikCore.Format
  def version, do: 1

  @impl WardrikCore.Format
  def dump(%__MODULE__{} = call),
    do: %{"id" => call.id, "name" => call.name, "arguments" => Term.dump(call.arguments)}

  @impl WardrikCore.Format
  def load(1, %{"id" => id, "name" => name, "arguments" => arguments}) do
    with {:ok, arguments} <- Term.load(arguments),
         do: {:ok, %__MODULE__{id: id, name: name, arguments: arguments}}
  end
end
