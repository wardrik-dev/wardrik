defmodule WardrikCore.Usage do
  @moduledoc false

  @type price() :: WardrikCore.price()

  @kinds [:input, :output, :cache_read, :cache_write]

  @spec measurements(ReqLLM.Response.t(), LLMDB.Model.t() | String.t(), map()) ::
          %{atom() => number()}
  def measurements(%ReqLLM.Response{} = response, model, prices) do
    usage = ReqLLM.Response.usage(response) || %{}

    tokens = %{
      input_tokens: Map.get(usage, :input_tokens, 0),
      output_tokens: Map.get(usage, :output_tokens, 0)
    }

    put_dollars(tokens, dollars(usage, model, prices))
  end

  @spec price(LLMDB.Model.t() | String.t()) :: price() | nil
  def price(model) do
    case ReqLLM.model(model) do
      {:ok, %LLMDB.Model{pricing: %{currency: "USD"}, cost: %{input: _, output: _} = cost}} ->
        for kind <- @kinds, is_number(cost[kind]), do: {kind, cost[kind]}

      _unpriced ->
        nil
    end
  end

  defp put_dollars(measurements, nil), do: Map.put(measurements, :unpriced_calls, 1)
  defp put_dollars(measurements, usd), do: Map.put(measurements, :usd, usd)

  defp dollars(usage, model, prices) do
    case ReqLLM.model(model) do
      {:ok, catalogued} ->
        priced(usage, catalogued, Map.get(prices, LLMDB.Model.spec(catalogued)))

      {:error, _reason} ->
        nil
    end
  end

  defp priced(usage, %LLMDB.Model{pricing: %{currency: "USD"}}, nil),
    do: Map.get(usage, :total_cost)

  defp priced(_usage, _model, nil), do: nil

  defp priced(usage, _model, price) do
    cache_read = tokens(usage, [:cache_read_tokens, :cached_tokens])
    cache_write = tokens(usage, [:cache_write_tokens, :cache_creation_tokens])
    input = max(tokens(usage, [:input_tokens]) - cache_read - cache_write, 0)

    (input * price[:input] + tokens(usage, [:output_tokens]) * price[:output] +
       cache_read * (price[:cache_read] || price[:input]) +
       cache_write * (price[:cache_write] || price[:input])) / 1_000_000
  end

  defp tokens(usage, keys), do: Enum.find_value(keys, 0, &positive(usage[&1]))

  defp positive(count) when is_integer(count) and count > 0, do: count
  defp positive(_count), do: nil
end
