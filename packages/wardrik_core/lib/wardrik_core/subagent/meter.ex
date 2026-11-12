defmodule WardrikCore.Subagent.Meter do
  @moduledoc false
  @behaviour WardrikCore.Middleware

  alias WardrikCore.Context
  alias WardrikCore.Subagent

  @enforce_keys [:table, :parent, :span, :name]
  defstruct @enforce_keys

  @impl WardrikCore.Middleware
  def call(%Context{step: :generate} = context, next, %__MODULE__{table: meter}),
    do: metered(context, next, meter)

  def call(
        %Context{step: {:tool_call, call}} = context,
        next,
        %__MODULE__{table: meter} = metered
      ) do
    true = :ets.insert(meter, {:call, call.id})
    progress(metered, call, tool_calls(meter))
    metered(context, next, meter)
  end

  def call(context, next, _meter), do: next.(context)

  @doc false
  @spec tool_calls(:ets.table()) :: non_neg_integer()
  def tool_calls(meter), do: length(:ets.match(meter, {:call, :_}))

  defp progress(%__MODULE__{parent: parent, span: span, name: name}, call, count) do
    Subagent.emit(parent, span, :progress, %{agent: %{name: name}, call: call, tool_calls: count})
  end

  @doc false
  @spec total(:ets.table()) :: map()
  def total(meter) do
    for {:gained, gained} <- :ets.tab2list(meter), reduce: %{} do
      total -> Map.merge(total, gained, fn _key, held, more -> held + more end)
    end
  end

  defp metered(context, next, meter) do
    result = next.(context)
    true = :ets.insert(meter, {:gained, gained(context.measurements, measured(result, context))})
    result
  end

  defp measured({:ok, after_step}, _context), do: after_step.measurements
  defp measured({:park, _reason, after_step}, _context), do: after_step.measurements
  defp measured({:error, _reason}, context), do: context.measurements

  defp gained(before, measured) do
    measured
    |> Map.new(fn {key, amount} -> {key, amount - Map.get(before, key, 0)} end)
    |> Map.reject(fn {_key, amount} -> amount == 0 end)
  end
end
