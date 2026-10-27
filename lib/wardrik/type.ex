defmodule Wardrik.Type do
  @moduledoc false

  defmacro __using__(opts) do
    schema = Keyword.fetch!(opts, :schema)
    fields = opts |> Keyword.fetch!(:fields) |> Macro.prewalk(&Macro.expand(&1, __CALLER__))

    quote do
      defstruct unquote(Keyword.keys(fields))

      @type t() :: %__MODULE__{}

      @doc false
      @spec __schema__() :: [String.t()]
      def __schema__, do: unquote(schema)

      @doc false
      @spec __fields__() :: keyword()
      def __fields__, do: unquote(Macro.escape(fields))

      @doc "Reads one from the protocol's JSON."
      @spec from_json(map()) :: t()
      def from_json(json), do: Wardrik.Type.decode(__MODULE__, __fields__(), json)

      @doc "Writes it as the protocol's JSON, leaving out what it doesn't set."
      @spec to_json(t()) :: map()
      def to_json(%__MODULE__{} = value), do: Wardrik.Type.encode(value, __fields__())
    end
  end

  @spec decode(module(), keyword(), map()) :: struct()
  def decode(module, fields, json),
    do: struct!(module, Enum.map(fields, fn {key, spec} -> {key, read(spec, json)} end))

  @spec encode(struct(), keyword()) :: map()
  def encode(value, fields) do
    for {key, spec} <- fields,
        path = path(spec),
        path != nil,
        written = write(Map.fetch!(value, key), spec),
        written != nil,
        reduce: %{} do
      json -> put_path(json, path, written)
    end
  end

  @doc "Turns keyword lists, maps, atoms and Wardrik's structs into the protocol's JSON."
  @spec json(term()) :: term()
  def json(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json(%Date{} = value), do: Date.to_iso8601(value)

  def json(%module{} = value) do
    if function_exported?(module, :to_json, 1), do: module.to_json(value), else: value
  end

  def json(fields) when is_map(fields),
    do: Map.new(fields, fn {key, value} -> {to_string(key), json(value)} end)

  def json([{key, _value} | _rest] = fields) when is_atom(key), do: fields |> Map.new() |> json()
  def json(values) when is_list(values), do: Enum.map(values, &json/1)
  def json(value) when is_boolean(value) or is_nil(value), do: value
  def json(value) when is_atom(value), do: Atom.to_string(value)
  def json(value), do: value

  @spec path(term()) :: [String.t()] | nil
  def path({path, _cast}), do: path(path)
  def path(nil), do: nil
  def path(path) when is_binary(path), do: String.split(path, ".")

  defp write(nil, _spec), do: nil
  defp write(values, {_path, [_module]}), do: Enum.map(values, &json/1)

  defp write(values, {_path, :reasons}),
    do: Enum.map(values, fn {id, why} -> %{"id" => id, "why" => why} end)

  defp write(value, _spec), do: json(value)

  defp put_path(json, [key], value), do: Map.put(json, key, value)

  defp put_path(json, [key | rest], value),
    do: Map.put(json, key, put_path(Map.get(json, key, %{}), rest, value))

  defp read(nil, _json), do: nil
  defp read({path, cast}, json), do: json |> get_in(path(path)) |> cast(cast)
  defp read(path, json), do: get_in(json, path(path))

  defp cast(nil, _cast), do: nil
  defp cast(values, [module]) when is_list(values), do: Enum.map(values, &module.from_json/1)
  defp cast(value, :datetime), do: datetime(value)
  defp cast(value, :date), do: Date.from_iso8601!(value)
  defp cast("infinity", :infinity), do: :infinity
  defp cast(value, :infinity), do: value
  defp cast(values, :reasons), do: Enum.map(values, &{&1["id"], &1["why"]})

  defp cast(value, atoms) when is_list(atoms),
    do: Enum.find(atoms, &(Atom.to_string(&1) == value))

  defp cast(value, module) when is_atom(module), do: module.from_json(value)

  defp datetime(text) do
    {:ok, datetime, _offset} = DateTime.from_iso8601(text)
    datetime
  end
end
