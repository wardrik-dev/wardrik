defmodule Tars.LLM.Cost do
  @moduledoc """
  What a model call cost, in US dollars.

      Tars.LLM.Cost.of(request.model_spec, ReqLLM.Response.usage(response))
      #=> 0.0042

  The provider's own `total_cost` when it reports one; otherwise the tokens
  priced by the model's entry in the catalog `Tars.LLM.Catalog` loads. A model
  the catalog does not price costs `nil`, which is not the same as nothing: a
  host enforcing a budget decides what an unpriced call counts as.
  """

  @doc "The cost of a call to `model_spec` that used `usage`, or `nil` where it cannot be priced."
  @spec of(term(), map() | nil) :: float() | nil
  def of(_model_spec, nil), do: nil
  def of(_model_spec, %{total_cost: total}) when is_number(total), do: total / 1

  def of(model_spec, usage) when is_map(usage) do
    with {:ok, model} <- ReqLLM.model(model_spec),
         %{total_cost: total} when is_number(total) <- ReqLLM.Usage.Cost.apply(usage, model) do
      total / 1
    else
      _unpriced -> nil
    end
  end

  @doc "Whether the catalog prices `model_spec`, so that `of/2` can price a call to it from its tokens."
  @spec priced?(term()) :: boolean()
  def priced?(model_spec), do: of(model_spec, %{input_tokens: 1, output_tokens: 1}) != nil

  @doc "The cost of the call that answered `response`. See `of/2`."
  @spec of_response(term(), ReqLLM.Response.t()) :: float() | nil
  def of_response(model_spec, %ReqLLM.Response{} = response),
    do: of(model_spec, ReqLLM.Response.usage(response))
end
