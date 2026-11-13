defmodule Wardrik.Store.Format do
  @moduledoc """
  The format of what a store keeps under a scope, so a release reads what an earlier one wrote.

  `Wardrik.Store` writes each value as JSON, `{"version": n, "value": ...}`, where `n` is the
  format's `c:version/0` and `value` is what `c:dump/1` returned. It reads a value back through
  `c:load/2`, which gets the version it was written with.

      defmodule MyApp.Theme do
        @behaviour Wardrik.Store.Format

        @impl true
        def version, do: 2

        @impl true
        def dump(%{name: name, dark: dark}), do: %{"name" => name, "dark" => dark}

        @impl true
        def load(2, %{"name" => name, "dark" => dark}), do: {:ok, %{name: name, dark: dark}}
        def load(1, name) when is_binary(name), do: {:ok, %{name: name, dark: false}}
      end

      themes = Wardrik.Store.scope(store, "my_app", format: MyApp.Theme)

    * Bump `c:version/0` when `c:dump/1` changes shape, and keep a `c:load/2` clause for each
      earlier version.
    * A value written by a later release, with a version above this one's, isn't read.

  `Wardrik.Store.Format.JSON`, a scope's format unless it names one, keeps JSON as it's given.
  """

  @typedoc "What JSON holds: maps with string keys, lists, strings, numbers, booleans and `nil`."
  @type json() :: %{String.t() => json()} | [json()] | String.t() | number() | boolean() | nil

  @doc "The version `c:dump/1` writes."
  @callback version() :: pos_integer()

  @doc "Returns `value` as JSON."
  @callback dump(value :: term()) :: json()

  @doc "Returns the value `json` holds, written at `version`, which is at most `c:version/0`."
  @callback load(version :: pos_integer(), json()) :: {:ok, term()} | {:error, String.t()}

  @doc false
  @spec encode(module(), term()) :: String.t()
  def encode(format, value) do
    json = format.dump(value)
    json!(json, format)
    JSON.encode!(%{"version" => format.version(), "value" => json})
  end

  # JSON would write an atom as a string, and read it back as one.
  defp json!(%{} = map, format) when not is_struct(map) do
    for {key, value} <- map do
      unless is_binary(key), do: not_json!(key, format)
      json!(value, format)
    end
  end

  defp json!(list, format) when is_list(list), do: Enum.each(list, &json!(&1, format))

  defp json!(value, format) when is_binary(value) do
    unless String.valid?(value), do: not_json!(value, format)
  end

  defp json!(value, _format) when is_number(value) or is_boolean(value) or is_nil(value), do: :ok
  defp json!(value, format), do: not_json!(value, format)

  defp not_json!(value, format),
    do:
      raise(
        ArgumentError,
        "#{inspect(format)}.dump/1 returned #{inspect(value)}, which isn't JSON"
      )

  @doc false
  @spec decode(module(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def decode(format, text) do
    %{"version" => version, "value" => value} = JSON.decode!(text)

    if version <= format.version(),
      do: format.load(version, value),
      else:
        {:error,
         "a later release wrote it at version #{version}; this one reads up to #{format.version()}"}
  end
end
