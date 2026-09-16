defmodule TarsTUI.Usage do
  @moduledoc """
  Token and cost totals for one agent, folded from `{:meta, chunk}` events.

  Usage is collected per request, keyed by the span the request runs on, with
  later records overwriting earlier ones. `settle/2` folds a span's request
  into the totals when its `{:model_finished, ...}` arrives, so concurrent
  requests on different spans add up.

  Cost is the provider's `total_cost` when present, otherwise what
  `ReqLLM.Usage.Cost` computes from the model's pricing, and zero for a model
  without pricing. The model is looked up in `ReqLLM` when the first request
  settles, not when the totals are created.
  """

  @type t() :: %__MODULE__{
          spec: term(),
          model: struct() | nil,
          priced?: boolean(),
          input: non_neg_integer(),
          output: non_neg_integer(),
          reasoning: non_neg_integer(),
          cached: non_neg_integer(),
          cost: float(),
          requests: non_neg_integer(),
          open: %{String.t() => map()}
        }

  defstruct spec: nil,
            model: nil,
            priced?: false,
            input: 0,
            output: 0,
            reasoning: 0,
            cached: 0,
            cost: 0.0,
            requests: 0,
            open: %{}

  @doc """
  Totals at zero, to be priced as `model_spec` once a request settles.
  """
  @spec new(term()) :: t()
  def new(model_spec \\ nil), do: %__MODULE__{spec: model_spec}

  # The model behind the spec, looked up once.
  defp price(%__MODULE__{priced?: true} = usage), do: usage
  defp price(%__MODULE__{spec: nil} = usage), do: %{usage | priced?: true}

  defp price(%__MODULE__{spec: spec} = usage) do
    case ReqLLM.model(spec) do
      {:ok, model} -> %{usage | model: model, priced?: true}
      _unknown -> %{usage | priced?: true}
    end
  end

  @doc """
  Records a metadata chunk seen on `span_id`.

  Anything without a `usage` map, such as a finish reason on its own, is
  ignored.
  """
  @spec observe(t(), String.t(), term()) :: t()
  def observe(%__MODULE__{} = usage, span_id, %{metadata: %{usage: seen}}) when is_map(seen) do
    %{usage | open: Map.update(usage.open, span_id, seen, &Map.merge(&1, seen))}
  end

  def observe(%__MODULE__{} = usage, _span_id, _chunk), do: usage

  @doc "Folds the request that ran on `span_id` into the totals."
  @spec settle(t(), String.t()) :: t()
  def settle(%__MODULE__{} = usage, span_id) do
    case Map.pop(usage.open, span_id) do
      {nil, _open} ->
        usage

      {seen, open} ->
        usage = price(usage)

        %{
          usage
          | open: open,
            requests: usage.requests + 1,
            input: usage.input + tokens(seen, :input_tokens),
            output: usage.output + tokens(seen, :output_tokens),
            reasoning: usage.reasoning + tokens(seen, :reasoning_tokens),
            cached: usage.cached + tokens(seen, :cached_tokens),
            cost: usage.cost + cost(seen, usage.model)
        }
    end
  end

  defp tokens(seen, key) do
    case Map.get(seen, key) do
      n when is_integer(n) and n >= 0 -> n
      _missing -> 0
    end
  end

  defp cost(%{total_cost: total}, _model) when is_number(total), do: total / 1
  defp cost(_seen, nil), do: 0.0

  defp cost(seen, model) do
    case ReqLLM.Usage.Cost.apply(seen, model) do
      %{total_cost: total} when is_number(total) -> total / 1
      _other -> 0.0
    end
  end

  @doc "Whether anything has been counted yet."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{requests: 0}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  One line of totals: the token counts as one group, then cost, then requests.
  Empty before the first request.
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{requests: 0}), do: ""

  def summary(%__MODULE__{} = usage) do
    tokens =
      [
        "↑ #{count(usage.input)} in",
        "↓ #{count(usage.output)} out",
        if(usage.reasoning > 0, do: "∿ #{count(usage.reasoning)} reasoning"),
        if(usage.cached > 0, do: "≡ #{count(usage.cached)} cached")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("  ")

    Enum.join([tokens, dollars(usage.cost), "#{usage.requests} req"], " · ")
  end

  @doc "A token count, abbreviated."
  @spec count(non_neg_integer()) :: String.t()
  def count(n) when n < 1_000, do: Integer.to_string(n)
  def count(n) when n < 1_000_000, do: "#{Float.round(n / 1_000, 1)}k"
  def count(n), do: "#{Float.round(n / 1_000_000, 2)}M"

  defp dollars(cost) when cost < 0.01, do: "$#{:erlang.float_to_binary(cost / 1, decimals: 4)}"
  defp dollars(cost), do: "$#{:erlang.float_to_binary(cost / 1, decimals: 2)}"
end
