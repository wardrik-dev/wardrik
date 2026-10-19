defmodule Wardrik.LLM.ReqLLM do
  @moduledoc """
  The `Wardrik.LLM.Client` that reaches every provider ReqLLM does, and a
  host's client unless it names another.

  A request's model spec is ReqLLM's, `"anthropic:claude-sonnet-5"` or
  `{:anthropic, model: "claude-sonnet-5"}`, and its `:generation` options
  are passed to the provider as `ReqLLM.stream_text/3` takes them. A
  provider's key is the request's `:api_key` where it carries one, as a
  dispatch or `Wardrik.LLM.Key` supplies it, and otherwise what ReqLLM finds
  in its config or the environment; `Wardrik.LLM.Client.model/2` names the
  secret, `ANTHROPIC_API_KEY` say, where it finds none. A model's window and
  its prices are the catalog's, which `Wardrik.LLM.Catalog` loads.

  What a provider attaches to its answers and expects back, such as the
  signatures of a model's reasoning, rides the conversation's `provider`
  maps; see `Wardrik.LLM.ReqLLM.Convert`.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl Wardrik.LLM.Client, for: Wardrik.LLM.ReqLLM do
  alias Wardrik.LLM.Model
  alias Wardrik.LLM.ReqLLM.Convert

  def stream(_client, request, emit) do
    with {:ok, streamed} <-
           ReqLLM.stream_text(
             request.model_spec,
             Convert.to_req_llm(request.context),
             Convert.opts(request.opts)
           ),
         {:ok, response} <-
           ReqLLM.StreamResponse.process_stream(streamed,
             on_result: &emit.({:text, &1}),
             on_thinking: &emit.({:reasoning, &1}),
             on_tool_call: &emit.({:tool_call, Convert.streamed(&1)})
           ) do
      {:ok, Convert.answer(response)}
    else
      {:error, reason} -> {:error, Convert.error(reason)}
    end
  end

  def generate(_client, request) do
    request.model_spec
    |> ReqLLM.generate_text(Convert.to_req_llm(request.context), Convert.opts(request.opts))
    |> answered()
  end

  def evaluate(_client, request, opts) do
    request.model_spec
    |> ReqLLM.evaluate(
      Keyword.fetch!(opts, :state),
      Keyword.fetch!(opts, :questions),
      Convert.evaluation_opts(request.opts)
    )
    |> answered()
  end

  def model(_client, spec) do
    with {:ok, %LLMDB.Model{} = model} <- ReqLLM.model(spec),
         do: {:ok, %Model{spec: spec, window: window(model), key: key(model)}}
  end

  def price(_client, spec, usage) do
    with {:ok, model} <- ReqLLM.model(spec),
         %{total_cost: total} when is_number(total) <-
           ReqLLM.Usage.Cost.apply(Convert.usage_map(usage), model) do
      total / 1
    else
      _unpriced -> nil
    end
  end

  defp answered({:ok, response}), do: {:ok, Convert.answer(response)}
  defp answered({:error, reason}), do: {:error, Convert.error(reason)}

  defp window(%LLMDB.Model{limits: %{context: context}}) when is_integer(context) and context > 0,
    do: context

  defp window(%LLMDB.Model{}), do: nil

  # A key ReqLLM finds itself needs no secret named.
  defp key(%LLMDB.Model{provider: provider} = model) do
    case ReqLLM.Keys.get(model) do
      {:ok, _key, _source} -> nil
      {:error, _none} -> ReqLLM.Keys.env_var_name(provider)
    end
  end
end
