defmodule Wardrik.Store.Format do
  @moduledoc false

  # Each value is kept as `{"version": n, "value": ...}`, in a `WardrikCore.Format`.

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
