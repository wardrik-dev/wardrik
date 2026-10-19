defmodule Wardrik.LLM.Runtime do
  @moduledoc """
  The `Wardrik.Runtime` whose turns ask a model: each a `Wardrik.LLM.Turn`,
  under the agent's `Wardrik.LLM.Config`. Its key is `model`.

  It reads a definition's `model`, `max_iterations` and `compaction` into
  a config, with the instructions and tools the definition resolved, over
  `:config`, the `Wardrik.LLM.Config` options every agent it reads gets:

      %Wardrik.LLM.Runtime{config: [tool_prices: %{"web_search" => 0.005}]}
  """

  defstruct config: []

  @type t() :: %__MODULE__{config: keyword()}
end

defimpl Wardrik.Runtime, for: Wardrik.LLM.Runtime do
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Turn

  def key(_runtime), do: "model"

  def read(%{config: config}, fields, context) do
    with {:ok, model} <- model(fields["model"]),
         {:ok, iterations} <- iterations(fields["max_iterations"]),
         {:ok, history} <- history(fields["compaction"]) do
      opts = [system: context.instructions, tools: context.tools] ++ config
      {:ok, Config.new(opts ++ model ++ iterations ++ history)}
    end
  end

  def turn(_runtime, run, opts),
    do: Turn.new(run, Keyword.fetch!(opts, :history), asked: Keyword.fetch!(opts, :asked))

  defp model(nil), do: {:ok, []}
  defp model(spec) when is_binary(spec), do: {:ok, model_spec: spec}
  defp model(_spec), do: {:error, "model is a string"}

  defp iterations(nil), do: {:ok, []}
  defp iterations(n) when is_integer(n) and n > 0, do: {:ok, max_iterations: n}
  defp iterations("infinity"), do: {:ok, max_iterations: :infinity}
  defp iterations(_n), do: {:error, "max_iterations is a whole number, or infinity"}

  defp history(nil), do: {:ok, []}
  defp history(false), do: {:ok, history: %Wardrik.History.All{}}

  defp history(%{} = fields) do
    case Map.keys(fields) -- ~w(at keep window) do
      [] ->
        with {:ok, at} <- share(fields, "at", 0.6),
             {:ok, keep} <- share(fields, "keep", 0.25),
             {:ok, window} <- window(fields["window"]),
             do: {:ok, history: Wardrik.Compaction.new(at: at, keep: keep, window: window)}

      [key | _rest] ->
        {:error, "compaction #{key} is not a setting; expected at, keep or window"}
    end
  end

  defp history(_other), do: {:error, "compaction is false, or a set of at, keep and window"}

  defp share(fields, key, default) do
    case Map.get(fields, key, default) do
      n when is_number(n) and n > 0 and n < 1 -> {:ok, n / 1}
      _other -> {:error, "compaction #{key} is a share of the window, between 0 and 1"}
    end
  end

  defp window(nil), do: {:ok, nil}
  defp window(n) when is_integer(n) and n > 0, do: {:ok, n}
  defp window(_n), do: {:error, "compaction window is a whole number of tokens"}
end
