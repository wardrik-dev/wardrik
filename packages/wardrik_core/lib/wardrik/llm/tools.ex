defmodule Wardrik.LLM.Tools do
  @moduledoc """
  A `Wardrik.Tool` as the model client reads it: `to_req_llm/1` for a request
  that offers it, and `validate/2` for the arguments of a call to it.

  The client never runs a tool. Every call runs through
  `Wardrik.Call.Pipeline`, so the `ReqLLM.Tool` a request offers carries a
  callback nothing calls.
  """

  @doc """
  `tool` as a request offers it. Raises `ArgumentError` on a name or schema
  no model could be offered.
  """
  @spec to_req_llm(Wardrik.Tool.t()) :: ReqLLM.Tool.t()
  def to_req_llm(%Wardrik.Tool{} = tool) do
    [
      name: tool.name,
      description: tool.description,
      parameter_schema: tool.schema,
      callback: fn _input -> {:error, "Wardrik runs its tools through its pipeline"} end
    ]
    |> ReqLLM.Tool.new()
    |> offered()
  end

  defp offered({:ok, tool}), do: tool
  defp offered({:error, error}), do: raise(ArgumentError, Exception.message(error))

  @doc """
  The `arguments` of a call to `tool`, checked against its schema, as the
  tool is handed them, or why they do not fit it.
  """
  @spec validate(Wardrik.Tool.t(), map()) :: {:ok, map()} | {:error, term()}
  def validate(%Wardrik.Tool{} = tool, arguments),
    do: tool |> to_req_llm() |> ReqLLM.Tool.validate_input(arguments)
end
