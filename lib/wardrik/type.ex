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
    end
  end

  @spec decode(module(), keyword(), map()) :: struct()
  def decode(module, fields, json),
    do: struct!(module, Enum.map(fields, fn {key, spec} -> {key, read(spec, json)} end))

  @doc "Turns keyword lists, maps and atoms into the protocol's JSON: string keys and values."
  @spec json(term()) :: term()
  def json(%_struct{} = value), do: value

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

  defp read(nil, _json), do: nil
  defp read({path, cast}, json), do: json |> get_in(path(path)) |> cast(cast)
  defp read(path, json), do: get_in(json, path(path))

  defp cast(nil, _cast), do: nil
  defp cast(values, [module]) when is_list(values), do: Enum.map(values, &module.from_json/1)
  defp cast(value, :datetime), do: datetime(value)
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
