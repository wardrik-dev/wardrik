defmodule Wardrik.LLM.Tools do
  @moduledoc """
  A `Wardrik.Tool` as ReqLLM reads it: `to_req_llm/1` for a request
  `Wardrik.LLM.ReqLLM` makes that offers it, `schema/1` for its parameters
  as a model is shown them, and `validate/2` for the arguments of a call to
  it, whichever client made the call.

  ReqLLM never runs a tool. Every call runs through
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

  @doc "The parameters of `tool` as the JSON Schema a model is shown."
  @spec schema(Wardrik.Tool.t()) :: map()
  def schema(%Wardrik.Tool{schema: schema}), do: ReqLLM.Schema.to_json(schema)

  @doc """
  The `arguments` of a call to `tool`, checked against its schema, as the
  tool is handed them, or why they do not fit it. Arguments the model wrote
  as something other than a JSON object fit no tool.
  """
  @spec validate(Wardrik.Tool.t(), map() | String.t()) :: {:ok, map()} | {:error, term()}
  def validate(%Wardrik.Tool{} = tool, arguments) when is_map(arguments),
    do: tool |> to_req_llm() |> ReqLLM.Tool.validate_input(arguments)

  def validate(%Wardrik.Tool{name: name}, arguments) when is_binary(arguments),
    do: {:error, "#{name} takes its arguments as a JSON object, and was given: #{arguments}"}
end
