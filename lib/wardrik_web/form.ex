defmodule WardrikWeb.Form do
  @moduledoc """
  A form built from a JSON Schema: fields for strings, numbers, switches and choices, fieldsets for
  objects, repeatable groups for arrays of objects, and a choice of shape for `oneOf`.

      <WardrikWeb.Form.fields schema={schema} params={@params} />

      {:ok, input} = WardrikWeb.Form.read(schema, params["input"])

    * Fields are named `input[...]`, so a form's params hold them under `"input"`.
    * `params/2` turns a value, such as a stored definition, into the params that show it.
    * A form that adds or removes groups handles `"form-add"` and `"form-remove"` with `add/2` and
      `remove/2`, and keeps `@params` from `phx-change`.
    * Empty fields are left out of what `read/2` gives.
  """

  use Phoenix.Component

  @long ~w(instructions prompt content description)
  @variant "__variant"

  @typedoc "A field's kind, from its schema."
  @type kind() ::
          :text
          | :long
          | :integer
          | :number
          | :switch
          | :choice
          | :const
          | :lines
          | :checks
          | :list
          | :object
          | :union
          | :json

  @doc "Returns the kind of field `schema` makes, given the field's `name`."
  @spec kind(map(), String.t() | nil) :: kind()
  def kind(schema, name \\ nil)
  # An object's oneOf, like "content or parts", constrains its fields; the server checks it.
  def kind(%{"type" => "object", "properties" => properties}, _name)
      when map_size(properties) > 0,
      do: :object

  def kind(%{"oneOf" => [_ | _]}, _name), do: :union
  def kind(%{"anyOf" => [_ | _]}, _name), do: :union
  def kind(%{"const" => _const}, _name), do: :const
  def kind(%{"enum" => [_ | _]}, _name), do: :choice

  def kind(%{"type" => [_ | _] = types} = schema, name),
    do: kind(%{schema | "type" => typed(types)}, name)

  def kind(%{"type" => "string"}, name) when name in @long, do: :long
  def kind(%{"type" => "string"}, _name), do: :text
  def kind(%{"type" => "integer"}, _name), do: :integer
  def kind(%{"type" => "number"}, _name), do: :number
  def kind(%{"type" => "boolean"}, _name), do: :switch
  def kind(%{"type" => "array", "items" => %{"enum" => [_ | _]}}, _name), do: :checks
  def kind(%{"type" => "array", "items" => %{"type" => "string"}}, _name), do: :lines
  def kind(%{"type" => "array", "items" => %{"properties" => %{}}}, _name), do: :list

  def kind(_schema, _name), do: :json

  defp typed(types), do: Enum.find(types, "string", &(&1 != "null"))

  ## Values to params

  @doc "Returns the params that show `value` in a form for `schema`."
  @spec params(map(), term()) :: term()
  def params(_schema, nil), do: nil
  def params(schema, value), do: params(kind(schema), schema, value)

  defp params(:object, %{"properties" => properties}, value) when is_map(value) do
    for {name, schema} <- properties,
        shown = params(schema, value[name]),
        shown != nil,
        into: %{},
        do: {name, shown}
  end

  defp params(:list, %{"items" => item}, value) when is_list(value) do
    for {each, index} <- Enum.with_index(value),
        into: %{},
        do: {Integer.to_string(index), params(item, each) || %{}}
  end

  defp params(:union, schema, value) do
    alternatives = alternatives(schema)
    index = Enum.find_index(alternatives, &fits?(&1, value)) || 0

    %{
      @variant => Integer.to_string(index),
      "value" => params(Enum.at(alternatives, index), value)
    }
  end

  defp params(:lines, _schema, value) when is_list(value), do: Enum.join(value, "\n")
  defp params(:checks, _schema, value) when is_list(value), do: value
  defp params(:const, _schema, _value), do: nil
  defp params(:json, _schema, value), do: Jason.encode!(value, pretty: true)
  defp params(_kind, _schema, value) when is_binary(value), do: value

  defp params(_kind, _schema, value) when is_number(value) or is_boolean(value),
    do: to_string(value)

  defp params(_kind, _schema, value), do: Jason.encode!(value)

  defp fits?(%{"const" => const}, value), do: const == value
  defp fits?(%{"enum" => choices}, value), do: value in choices

  defp fits?(%{"type" => [_ | _] = types} = schema, value),
    do: Enum.any?(types, &fits?(%{schema | "type" => &1}, value))

  defp fits?(%{"type" => "string"}, value), do: is_binary(value)
  defp fits?(%{"type" => "integer"}, value), do: is_integer(value)
  defp fits?(%{"type" => "number"}, value), do: is_number(value)
  defp fits?(%{"type" => "boolean"}, value), do: is_boolean(value)
  defp fits?(%{"type" => "array"}, value), do: is_list(value)
  defp fits?(%{"type" => "object"}, value), do: is_map(value)
  defp fits?(%{"type" => "null"}, value), do: is_nil(value)
  defp fits?(_schema, _value), do: false

  defp alternatives(schema), do: schema["oneOf"] || schema["anyOf"]

  ## Params to values

  @doc "Reads `params` as a value of `schema`. Empty fields are left out; `:none` when all are."
  @spec read(map(), term()) :: {:ok, term()} | :none | {:error, String.t()}
  def read(schema, params), do: read(kind(schema), schema, params, [])

  defp read(:object, %{"properties" => properties}, params, path) when is_map(params) do
    Enum.reduce_while(properties, {:ok, %{}}, fn {name, schema}, {:ok, map} ->
      case read(kind(schema, name), schema, params[name], path ++ [name]) do
        {:ok, value} -> {:cont, {:ok, Map.put(map, name, value)}}
        :none -> {:cont, {:ok, map}}
        {:error, _why} = error -> {:halt, error}
      end
    end)
    |> none_if_empty()
  end

  defp read(:list, %{"items" => item}, params, path) when is_map(params) do
    params
    |> Enum.sort_by(fn {index, _item} -> String.to_integer(index) end)
    |> Enum.reduce_while({:ok, []}, fn {index, each}, {:ok, list} ->
      case read(kind(item), item, each, path ++ [index]) do
        {:ok, value} -> {:cont, {:ok, list ++ [value]}}
        :none -> {:cont, {:ok, list}}
        {:error, _why} = error -> {:halt, error}
      end
    end)
    |> none_if_empty()
  end

  defp read(:union, schema, %{@variant => variant} = params, path) when variant != "" do
    alternative = Enum.at(alternatives(schema), String.to_integer(variant))

    case alternative do
      %{"const" => const} -> {:ok, const}
      alternative -> read(kind(alternative), alternative, params["value"], path)
    end
  end

  defp read(:checks, _schema, [_ | _] = values, _path),
    do: {:ok, Enum.reject(values, &(&1 == ""))} |> none_if_empty()

  defp read(kind, _schema, text, path) when is_binary(text) do
    case value(kind, String.trim(text)) do
      :none -> :none
      {:ok, value} -> {:ok, value}
      :error -> {:error, "#{Enum.join(path, ".")} doesn't read as #{describe(kind)}."}
    end
  end

  defp read(_kind, _schema, _params, _path), do: :none

  defp none_if_empty({:ok, empty}) when empty in [%{}, []], do: :none
  defp none_if_empty(other), do: other

  defp value(_kind, ""), do: :none
  defp value(kind, text) when kind in [:text, :long, :choice], do: {:ok, text}
  defp value(:switch, text), do: {:ok, text == "true"}

  defp value(:lines, text),
    do: {:ok, text |> String.split("\n") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}

  defp value(:integer, text) do
    case Integer.parse(text) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  defp value(:number, text) do
    case Float.parse(text) do
      {number, ""} ->
        {:ok,
         if(number == trunc(number) and not String.contains?(text, "."),
           do: trunc(number),
           else: number
         )}

      _other ->
        :error
    end
  end

  defp value(:json, text) do
    case JSON.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  defp value(_kind, _text), do: :error

  defp describe(:json), do: "JSON"
  defp describe(:integer), do: "a whole number"
  defp describe(:number), do: "a number"
  defp describe(kind), do: Atom.to_string(kind)

  ## Groups

  @doc """
  Handles the form's own events, `"form-add"` and `"form-remove"`, on `params`. Returns `nil` for
  any other event.
  """
  @spec handle(String.t(), map(), map() | nil) :: map() | nil
  def handle("form-add", %{"path" => path}, params), do: add(params, Jason.decode!(path))
  def handle("form-remove", %{"path" => path}, params), do: remove(params, Jason.decode!(path))
  def handle(_event, _value, _params), do: nil

  @doc "Adds an empty group to the array of objects at `path` in `params`."
  @spec add(map() | nil, [String.t()]) :: map()
  def add(params, path) do
    change(params || %{}, path, fn groups ->
      groups = groups || %{}
      next = groups |> Map.keys() |> Enum.map(&String.to_integer/1) |> Enum.max(fn -> -1 end)
      Map.put(groups, Integer.to_string(next + 1), %{})
    end)
  end

  @doc "Removes the group at `path` in `params`."
  @spec remove(map() | nil, [String.t()]) :: map()
  def remove(params, path) do
    {index, parent} = List.pop_at(path, -1)
    change(params || %{}, parent, &Map.delete(&1 || %{}, index))
  end

  defp change(map, [], fun), do: fun.(map)
  defp change(map, [key | rest], fun), do: Map.put(map, key, change(map[key] || %{}, rest, fun))

  ## Rendering

  @doc """
  The fields of an object `schema`, showing `params`. `:only` and `:except` pick its top-level
  properties; required ones come first.
  """
  attr :schema, :map, required: true
  attr :params, :any, default: %{}
  attr :only, :list, default: nil
  attr :except, :list, default: []
  attr :target, :any, default: nil, doc: "The `phx-target` of the add and remove buttons."

  def fields(assigns) do
    required = Map.get(assigns.schema, "required", [])

    properties =
      assigns.schema
      |> Map.get("properties", %{})
      |> Enum.filter(fn {name, _schema} ->
        (assigns.only == nil or name in assigns.only) and name not in assigns.except
      end)
      |> Enum.sort_by(fn {name, _schema} ->
        {name not in required, Enum.find_index(assigns.only || [], &(&1 == name)) || 0, name}
      end)

    assigns = assign(assigns, properties: properties, required: required)

    ~H"""
    <.field
      :for={{name, schema} <- @properties}
      schema={schema}
      path={[name]}
      label={name}
      required={name in @required}
      params={(@params || %{})[name]}
      target={@target}
    />
    """
  end

  attr :schema, :map, required: true
  attr :path, :list, required: true
  attr :label, :string, required: true
  attr :required, :boolean, default: false
  attr :params, :any, default: nil
  attr :target, :any, default: nil

  defp field(assigns) do
    assigns =
      assign(assigns,
        kind: kind(assigns.schema, List.last(assigns.path)),
        name: name(assigns.path),
        id: "f-" <> Enum.join(assigns.path, "-")
      )

    render_field(assigns)
  end

  defp render_field(%{kind: :object} = assigns) do
    assigns = assign(assigns, :open, assigns.required or filled?(assigns.params))

    ~H"""
    <details class="group" open={@open}>
      <summary><.label label={@label} required={@required} /></summary>
      <div :if={@schema["description"]} class="hint">{@schema["description"]}</div>
      <.field
        :for={{name, schema} <- @schema["properties"]}
        schema={schema}
        path={@path ++ [name]}
        label={name}
        required={name in Map.get(@schema, "required", [])}
        params={(@params || %{})[name]}
        target={@target}
      />
    </details>
    """
  end

  defp render_field(%{kind: :list} = assigns) do
    groups =
      (assigns.params || %{})
      |> Enum.sort_by(fn {index, _group} -> String.to_integer(index) end)

    assigns = assign(assigns, groups: groups, item: assigns.schema["items"])

    ~H"""
    <div class="field">
      <.label label={@label} required={@required} />
      <div :if={@schema["description"]} class="hint">{@schema["description"]}</div>
      <fieldset :for={{index, group} <- @groups} class="item">
        <legend>
          #{String.to_integer(index) + 1}
          <button
            type="button"
            class="btn small danger"
            phx-click="form-remove"
            phx-target={@target}
            phx-value-path={Jason.encode!(@path ++ [index])}
          >
            Remove
          </button>
        </legend>
        <.field
          :for={{name, schema} <- @item["properties"]}
          schema={schema}
          path={@path ++ [index, name]}
          label={name}
          required={name in Map.get(@item, "required", [])}
          params={(group || %{})[name]}
          target={@target}
        />
      </fieldset>
      <button
        type="button"
        class="btn small"
        phx-click="form-add"
        phx-target={@target}
        phx-value-path={Jason.encode!(@path)}
      >
        Add {@label}
      </button>
    </div>
    """
  end

  defp render_field(%{kind: :union} = assigns) do
    alternatives = alternatives(assigns.schema)
    variant = (assigns.params || %{})[@variant] || ""
    chosen = if variant != "", do: Enum.at(alternatives, String.to_integer(variant))

    assigns =
      assign(assigns,
        choices:
          alternatives
          |> Enum.with_index()
          |> Enum.map(fn {a, i} -> {shape(a), Integer.to_string(i)} end),
        variant: variant,
        chosen: chosen
      )

    ~H"""
    <div class="field">
      <.label label={@label} required={@required} for={@id} />
      <select id={@id} name={name(@path ++ ["__variant"])}>
        <option value="">—</option>
        <option :for={{shape, index} <- @choices} value={index} selected={index == @variant}>
          {shape}
        </option>
      </select>
      <div :if={@schema["description"]} class="hint">{@schema["description"]}</div>
      <div :if={@chosen && kind(@chosen) != :const} class="variant">
        <.field
          schema={@chosen}
          path={@path ++ ["value"]}
          label={shape(@chosen)}
          params={(@params || %{})["value"]}
          target={@target}
        />
      </div>
    </div>
    """
  end

  defp render_field(assigns) do
    ~H"""
    <div class="field">
      <.label label={@label} required={@required} for={@id} />
      <.input kind={@kind} id={@id} name={@name} schema={@schema} value={@params} />
      <div :if={@schema["description"]} class="hint">{@schema["description"]}</div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :required, :boolean, default: false
  attr :for, :string, default: nil

  defp label(assigns) do
    ~H"""
    <label for={@for}><code>{@label}</code><span :if={@required} class="req">required</span></label>
    """
  end

  attr :kind, :atom, required: true
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :schema, :map, required: true
  attr :value, :any, default: nil

  defp input(%{kind: kind} = assigns) when kind in [:choice, :switch] do
    choices =
      if kind == :switch,
        do: ["true", "false"],
        else: Enum.map(assigns.schema["enum"], &to_string/1)

    assigns = assign(assigns, :choices, choices)

    ~H"""
    <select id={@id} name={@name}>
      <option value="">—</option>
      <option :for={choice <- @choices} value={choice} selected={choice == @value}>{choice}</option>
    </select>
    """
  end

  defp input(%{kind: :checks} = assigns) do
    assigns = assign(assigns, :choices, assigns.schema["items"]["enum"])

    ~H"""
    <div class="checks" id={@id}>
      <input type="hidden" name={@name <> "[]"} value="" />
      <label :for={choice <- @choices} class="check">
        <input
          type="checkbox"
          name={@name <> "[]"}
          value={choice}
          checked={choice in List.wrap(@value)}
        />
        {choice}
      </label>
    </div>
    """
  end

  defp input(%{kind: kind} = assigns) when kind in [:long, :lines, :json] do
    assigns =
      assign(assigns,
        placeholder: %{lines: "One a line", json: "JSON", long: nil}[kind],
        class: if(kind == :long, do: "prose")
      )

    ~H"""
    <textarea id={@id} name={@name} placeholder={@placeholder} class={@class}>{@value}</textarea>
    """
  end

  defp input(assigns) do
    assigns =
      assign(assigns,
        type: if(assigns.kind in [:integer, :number], do: "number", else: "text"),
        step: if(assigns.kind == :number, do: "any")
      )

    ~H"""
    <input id={@id} type={@type} step={@step} name={@name} value={@value} />
    """
  end

  defp name(path), do: "input" <> Enum.map_join(path, &("[" <> &1 <> "]"))

  defp shape(%{"title" => title}), do: title
  defp shape(%{"const" => const}), do: inspect(const)

  defp shape(schema) do
    case kind(schema) do
      :object -> "fields"
      :list -> "list of groups"
      :lines -> "list"
      :checks -> "choices"
      :long -> "text"
      :choice -> "choice"
      :json -> "JSON"
      kind -> Atom.to_string(kind)
    end
  end

  defp filled?(nil), do: false
  defp filled?(""), do: false
  defp filled?(map) when is_map(map), do: Enum.any?(map, fn {_key, value} -> filled?(value) end)
  defp filled?(list) when is_list(list), do: Enum.any?(list, &filled?/1)
  defp filled?(_value), do: true
end
