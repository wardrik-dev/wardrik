defmodule TarsLua.Sandbox do
  @moduledoc """
  A `Tars.Sandbox` over [lua](https://hexdocs.pm/lua), a Lua 5.3 VM written in
  pure Elixir.

      Tars.Sandbox.run(TarsLua.Sandbox, "return ('%d apples'):format(3)", Tars.Sandbox.Limits.new())
      #=> {:ok, "3 apples"}

  The VM has no way to reach the node: `io`, `file`, `os.execute`, `os.exit`,
  `os.getenv`, `package`, `require`, `load`, `dofile`, `print` and `debug`
  raise when called. `string`, `table`, `math`, `utf8` and the rest of `os`
  are there.

  A chunk hands back what it returns: one value as itself, several as a list,
  none as `nil`. A table comes back as a map, or as a list when its keys are
  exactly 1..n.

  `Tars.Sandbox.Runner` carries the deadline and the memory budget. The VM
  enforces the rest of `t:Tars.Sandbox.Limits.t/0` itself, and reports each as
  a sentence: a step budget spent, a call stack too deep, a string too large
  to build.
  """

  @behaviour Tars.Sandbox

  alias Tars.Sandbox.Limits

  @max_code_bytes 64 * 1024

  @impl Tars.Sandbox
  def check(code) when not is_binary(code) do
    {:error, "code must be a string, got: #{inspect(code)}"}
  end

  def check(code) when byte_size(code) > @max_code_bytes do
    {:error, "code is #{byte_size(code)} bytes, longer than the #{@max_code_bytes} allowed"}
  end

  def check(code) do
    case Lua.parse_chunk(code) do
      {:ok, _chunk} -> :ok
      {:error, exception} -> {:error, Exception.message(exception)}
    end
  end

  @impl Tars.Sandbox
  def evaluate(code, %Limits{} = limits) do
    {results, _lua} = Lua.eval!(vm(limits), code)
    {:ok, value(results)}
  rescue
    error in [Lua.RuntimeException, Lua.CompilerException] -> {:error, Exception.message(error)}
  end

  defp vm(limits) do
    [
      max_call_depth: limits.max_depth,
      max_instructions: limits.max_steps,
      max_string_bytes: string_bytes(limits.max_heap_bytes)
    ]
    |> Lua.new()
    |> Lua.sandbox([:print])
    |> Lua.sandbox([:debug])
  end

  # Refusing a single string a quarter the size of the budget leaves the rest
  # of the evaluation room to hold it.
  defp string_bytes(:infinity), do: :infinity
  defp string_bytes(max_heap_bytes), do: div(max_heap_bytes, 4)

  defp value([]), do: nil
  defp value([single]), do: decode(single)
  defp value(many), do: Enum.map(many, &decode/1)

  defp decode(table) when is_list(table) do
    pairs = Map.new(table)
    size = map_size(pairs)

    if Enum.all?(1..size//1, &is_map_key(pairs, &1)) do
      for index <- 1..size//1, do: decode(pairs[index])
    else
      Map.new(pairs, fn {key, value} -> {decode(key), decode(value)} end)
    end
  end

  defp decode(other), do: other
end
