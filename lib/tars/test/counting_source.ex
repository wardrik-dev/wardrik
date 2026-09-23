defmodule Tars.Test.CountingSource do
  @moduledoc "A `Tars.Tool` source that gives as many numbered tools as it is asked for."

  @behaviour Tars.Tool

  @impl true
  def tools(count) when is_integer(count) do
    for index <- 1..count//1, do: tool("counted_#{index}")
  end

  def tools(names) when is_list(names), do: Enum.map(names, &tool/1)

  @impl true
  def timeout, do: :timer.seconds(90)

  defp tool(name) do
    ReqLLM.Tool.new!(
      name: name,
      description: "Counted tool #{name}.",
      parameter_schema: [value: [type: :any, required: false, doc: "Anything"]],
      callback: {__MODULE__, :run, [name]}
    )
  end

  def run(name, params), do: {:ok, Map.put(Map.new(params), :from, name)}
end
