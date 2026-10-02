defmodule WardrikLua.Sandbox do
  @moduledoc """
  A `Wardrik.Sandbox` over [lua](https://hexdocs.pm/lua), a Lua 5.3 VM written in
  pure Elixir.

      Wardrik.Sandbox.run(WardrikLua.Sandbox, "return ('%d apples'):format(3)", Wardrik.Sandbox.Limits.new())
      #=> {:ok, "3 apples"}

  The VM has no way to reach the node: `io`, `file`, `os.execute`, `os.exit`,
  `os.getenv`, `package`, `require`, `load`, `dofile`, `print` and `debug`
  raise when called. `string`, `table`, `math`, `utf8` and the rest of `os`
  are there.

  A chunk hands back what it returns: one value as itself, several as a list,
  none as `nil`. A table comes back as a map, or as a list when its keys are
  exactly 1..n. Object keys become strings; keys that collide after conversion
  are refused. Functions, cyclic tables and strings that are not UTF-8 cannot
  be returned as JSON and are refused too.

  `Wardrik.Sandbox.Runner` carries the deadline and the memory budget. The VM
  enforces the rest of `t:Wardrik.Sandbox.Limits.t/0` itself, and reports each as
  a sentence: a step budget spent, a call stack too deep, a string too large
  to build.
  """

  @behaviour Wardrik.Sandbox

  alias Wardrik.Sandbox.Limits

  @max_code_bytes 64 * 1024

  @impl Wardrik.Sandbox
  def check(code) when not is_binary(code) do
    {:error, "code must be a string, got: #{inspect(code)}"}
  end

  def check(code) when byte_size(code) > @max_code_bytes do
    {:error, "code is #{byte_size(code)} bytes, longer than the #{@max_code_bytes} allowed"}
  end

  # Parsing also compiles the chunk. Leave that work to evaluate/2 so both
  # compilation and execution run under the caller's resource limits.
  def check(_code), do: :ok

  @impl Wardrik.Sandbox
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
      Enum.reduce(pairs, %{}, &put_entry/2)
    end
  end

  defp decode(value) when is_binary(value) do
    if String.valid?(value),
      do: value,
      else: raise(Lua.RuntimeException, "returned strings must be valid UTF-8")
  end

  defp decode(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value

  defp decode(_other),
    do:
      raise(
        Lua.RuntimeException,
        "cannot return functions, cyclic tables or other opaque Lua values as JSON"
      )

  defp object_key(key) when is_binary(key), do: decode(key)
  defp object_key(key) when is_number(key) or is_boolean(key), do: to_string(key)

  defp object_key(_key),
    do: raise(Lua.RuntimeException, "returned table keys must be strings, numbers or booleans")

  defp put_entry({key, value}, object) do
    key = object_key(key)

    if Map.has_key?(object, key) do
      raise Lua.RuntimeException,
            "returned table has keys that collide as JSON key #{inspect(key)}"
    end

    Map.put(object, key, decode(value))
  end
end
