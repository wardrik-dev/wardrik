defmodule WardrikTUI.Usage do
  @moduledoc """
  Token and cost totals for one agent, folded from its
  `Wardrik.Bus.ModelFinished` events.

  Each model call that answered adds what it used, as its
  `Wardrik.LLM.Answer` reports it, and what it cost, as the event carries
  it: the provider's figure, or the tokens as the host's model client prices
  them, and nothing for a call nobody prices. A call that never answered
  adds nothing.
  """

  alias Wardrik.Bus
  alias Wardrik.Bus.ModelFinished
  alias Wardrik.LLM.Answer

  @type t() :: %__MODULE__{
          input: non_neg_integer(),
          output: non_neg_integer(),
          reasoning: non_neg_integer(),
          cached: non_neg_integer(),
          cost: float(),
          requests: non_neg_integer()
        }

  defstruct input: 0, output: 0, reasoning: 0, cached: 0, cost: 0.0, requests: 0

  @doc "Totals at zero."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Adds the model call a `Wardrik.Bus.ModelFinished` reports, where it answered."
  @spec settle(t(), Bus.Event.t()) :: t()
  def settle(%__MODULE__{} = usage, %Bus.Event{payload: %ModelFinished{answer: nil}}), do: usage

  def settle(
        %__MODULE__{} = usage,
        %Bus.Event{payload: %ModelFinished{answer: %Answer{usage: used}, cost: cost}}
      ) do
    used = used || %Wardrik.LLM.Usage{}

    %{
      usage
      | requests: usage.requests + 1,
        input: usage.input + tokens(used.input_tokens),
        output: usage.output + tokens(used.output_tokens),
        reasoning: usage.reasoning + tokens(used.reasoning_tokens),
        cached: usage.cached + tokens(used.cached_tokens),
        cost: usage.cost + dollars(cost)
    }
  end

  defp tokens(n) when is_integer(n) and n >= 0, do: n
  defp tokens(_missing), do: 0

  defp dollars(%{micro_usd: micro_usd}), do: micro_usd / 1_000_000
  defp dollars(nil), do: 0.0

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

    Enum.join([tokens, cost(usage.cost), "#{usage.requests} req"], " · ")
  end

  @doc "A token count, abbreviated."
  @spec count(non_neg_integer()) :: String.t()
  def count(n) when n < 1_000, do: Integer.to_string(n)
  def count(n) when n < 1_000_000, do: "#{Float.round(n / 1_000, 1)}k"
  def count(n), do: "#{Float.round(n / 1_000_000, 2)}M"

  defp cost(cost) when cost < 0.01, do: "$#{:erlang.float_to_binary(cost / 1, decimals: 4)}"
  defp cost(cost), do: "$#{:erlang.float_to_binary(cost / 1, decimals: 2)}"
end
