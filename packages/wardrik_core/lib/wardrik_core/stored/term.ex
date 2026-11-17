defmodule WardrikCore.Stored.Term do
  @moduledoc false

  # Keeps data whose shape another library or your app decides, such as a provider's metadata on
  # a message, as JSON that reads back the same. JSON's own values are kept as they are. Others
  # are tagged: `{"$atom": "anthropic"}`, `{"$bytes": base64}`, `{"$tuple": [...]}`,
  # `{"$datetime": iso8601}`, a map with atom keys as `{"$atom_keys": {...}}`, and any other map
  # as `{"$map": [[key, value], ...]}`.

  @spec dump(term()) :: Wardrik.Format.json()
  def dump(value) when is_nil(value) or is_boolean(value) or is_number(value), do: value
  def dump(value) when is_atom(value), do: %{"$atom" => Atom.to_string(value)}

  def dump(value) when is_binary(value) do
    if String.valid?(value), do: value, else: %{"$bytes" => Base.encode64(value)}
  end

  def dump(value) when is_list(value), do: Enum.map(value, &dump/1)
  def dump(value) when is_tuple(value), do: %{"$tuple" => dump(Tuple.to_list(value))}
  def dump(%DateTime{} = value), do: %{"$datetime" => DateTime.to_iso8601(value)}

  def dump(%_{} = value),
    do: raise(ArgumentError, "#{inspect(value)} can't be kept: give its kind a format")

  def dump(value) when is_map(value), do: map(value)

  defp map(value) do
    cond do
      Enum.all?(value, fn {key, _value} -> plain?(key) end) ->
        Map.new(value, fn {key, value} -> {key, dump(value)} end)

      Enum.all?(value, fn {key, _value} -> is_atom(key) end) ->
        %{
          "$atom_keys" =>
            Map.new(value, fn {key, value} -> {Atom.to_string(key), dump(value)} end)
        }

      true ->
        %{"$map" => Enum.map(value, fn {key, value} -> [dump(key), dump(value)] end)}
    end
  end

  defp plain?(key), do: is_binary(key) and not String.starts_with?(key, "$")

  @spec load(Wardrik.Format.json()) :: {:ok, term()} | {:error, String.t()}
  def load(json) do
    {:ok, load_or_throw(json)}
  catch
    {:unreadable, reason} -> {:error, reason}
  end

  @doc "As `load/1`, but throws `{:unreadable, reason}`, for codecs that read many values."
  @spec load_or_throw(Wardrik.Format.json()) :: term()
  def load_or_throw(%{"$atom" => name}), do: atom!(name)
  def load_or_throw(%{"$bytes" => bytes}), do: Base.decode64!(bytes)

  def load_or_throw(%{"$tuple" => items}) do
    items
    |> Enum.map(&load_or_throw/1)
    |> List.to_tuple()
  end

  def load_or_throw(%{"$datetime" => iso}) do
    {:ok, value, _offset} = DateTime.from_iso8601(iso)
    value
  end

  def load_or_throw(%{"$atom_keys" => map}),
    do: Map.new(map, fn {key, value} -> {atom!(key), load_or_throw(value)} end)

  def load_or_throw(%{"$map" => pairs}),
    do: Map.new(pairs, fn [key, value] -> {load_or_throw(key), load_or_throw(value)} end)

  def load_or_throw(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, load_or_throw(value)} end)

  def load_or_throw(list) when is_list(list), do: Enum.map(list, &load_or_throw/1)
  def load_or_throw(value), do: value

  @doc "Returns the atom `name`, which this release must already have, or throws."
  @spec atom!(String.t()) :: atom()
  def atom!(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> throw({:unreadable, "it names #{name}, which this release doesn't have"})
  end
end
