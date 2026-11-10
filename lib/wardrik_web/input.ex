defmodule WardrikWeb.Input do
  @moduledoc """
  Turns an operation's input schema into form fields, and a form's params into its input.

      fields = WardrikWeb.Input.fields(WardrikProtocol.operation("agent.ask"))
      {:ok, %{"agent" => "triage", "content" => "Hi"}} =
        WardrikWeb.Input.read(fields, %{"agent" => "triage", "content" => "Hi"})

  A field is `:text`, `:number`, `:choice`, `:switch`, `:lines` (an array of strings, one a line)
  or `:json` (anything else). Empty fields are left out.
  """

  defmodule Field do
    @moduledoc "One field of an operation's input form."
    @enforce_keys [:name, :kind]
    defstruct [:name, :kind, :description, required: false, choices: []]

    @type kind() :: :text | :number | :choice | :switch | :lines | :json
    @type t() :: %__MODULE__{
            name: String.t(),
            kind: kind(),
            description: String.t() | nil,
            required: boolean(),
            choices: [String.t()]
          }
  end

  @doc "Returns the operation's input fields: required first, then in name order."
  @spec fields(WardrikProtocol.operation()) :: [Field.t()]
  def fields(%{input: input}) do
    required = Map.get(input, "required", [])

    input
    |> Map.get("properties", %{})
    |> Enum.map(fn {name, schema} ->
      %Field{
        name: name,
        kind: kind(schema),
        description: schema["description"],
        required: name in required,
        choices: Map.get(schema, "enum", [])
      }
    end)
    |> Enum.sort_by(&{not &1.required, &1.name})
  end

  defp kind(%{"enum" => [_ | _]}), do: :choice
  defp kind(%{"type" => "string"}), do: :text
  defp kind(%{"type" => type}) when type in ["integer", "number"], do: :number
  defp kind(%{"type" => "boolean"}), do: :switch
  defp kind(%{"type" => "array", "items" => %{"type" => "string"}}), do: :lines
  defp kind(_schema), do: :json

  @doc "Reads the form's `params` into the operation's input, or says which field doesn't read."
  @spec read([Field.t()], map()) :: {:ok, map()} | {:error, String.t()}
  def read(fields, params) do
    Enum.reduce_while(fields, {:ok, %{}}, fn field, {:ok, input} ->
      case value(field.kind, String.trim(params[field.name] || "")) do
        :none -> {:cont, {:ok, input}}
        {:ok, value} -> {:cont, {:ok, Map.put(input, field.name, value)}}
        :error -> {:halt, {:error, "#{field.name} doesn't read as #{field.kind}."}}
      end
    end)
  end

  defp value(_kind, ""), do: :none
  defp value(kind, text) when kind in [:text, :choice], do: {:ok, text}
  defp value(:switch, text), do: {:ok, text == "true"}

  defp value(:lines, text),
    do: {:ok, text |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}

  defp value(:number, text) do
    case Integer.parse(text) do
      {number, ""} -> {:ok, number}
      _other -> float(text)
    end
  end

  defp value(:json, text) do
    case JSON.decode(text) do
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> :error
    end
  end

  defp float(text) do
    case Float.parse(text) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end
end
