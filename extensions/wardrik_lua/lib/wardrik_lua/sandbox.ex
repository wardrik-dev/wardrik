defmodule WardrikLua.Sandbox do
  @moduledoc """
  Runs Lua code under limits, with no access to the node.

      WardrikLua.Sandbox.run("return ('%d apples'):format(3)", WardrikLua.Sandbox.Limits.new())
      #=> {:ok, "3 apples"}

    * `string`, `table`, `math`, `utf8` and the safe parts of `os` work. `io`, `file`,
      `os.execute`, `os.exit`, `os.getenv`, `package`, `require`, `load`, `dofile`, `print` and
      `debug` raise.
    * No value returns `nil`, one returns itself, several return a list.
    * A table returns a map, or a list when its keys are exactly `1..n`. Map keys become strings.
    * Functions, cyclic tables, invalid UTF-8 and colliding keys are errors.
    * Errors are sentences, since a model reads them.
  """

  alias WardrikLua.Sandbox.Limits
  alias WardrikLua.Sandbox.Runner

  @typedoc "The value the code returned, or why it failed."
  @type result() :: {:ok, term()} | {:error, String.t()}

  @max_code_bytes 64 * 1024

  @doc "Checks `code` with `check/1`, then evaluates it in a task of its own under `limits`."
  @spec run(String.t(), Limits.t()) :: result()
  def run(code, %Limits{} = limits) do
    with :ok <- check(code) do
      Runner.run(fn -> evaluate(code, limits) end, limits)
    end
  end

  @doc "Returns `:ok` if `code` is a string of at most 64 KB, or an error."
  @spec check(term()) :: :ok | {:error, String.t()}
  def check(code) when not is_binary(code) do
    {:error, "code must be a string, got: #{inspect(code)}"}
  end

  def check(code) when byte_size(code) > @max_code_bytes do
    {:error, "code is #{byte_size(code)} bytes, longer than the #{@max_code_bytes} allowed"}
  end

  # Parsing also compiles the chunk. Leave that work to evaluate/2 so both
  # compilation and execution run under the caller's resource limits.
  def check(_code), do: :ok

  @doc "Evaluates `code` in this process, under only the step and depth limits."
  @spec evaluate(String.t(), Limits.t()) :: result()
  def evaluate(code, %Limits{} = limits) do
    vm = vm(limits)
    {results, _lua} = Lua.eval!(vm, code)
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
