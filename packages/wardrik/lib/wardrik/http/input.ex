defmodule Wardrik.HTTP.Input do
  @moduledoc false

  alias Plug.Conn.Unfetched
  alias Wardrik.Error
  alias Wardrik.HTTP.BodyReader

  @limit 8_000_000

  @doc "Returns the input for `operation` from `conn` and the path `params` it was routed by."
  @spec build(Plug.Conn.t(), WardrikProtocol.operation(), map()) ::
          {:ok, map(), Plug.Conn.t()} | {:error, Error.t()}
  def build(conn, operation, params) do
    with {:ok, body, conn} <- body(conn, operation) do
      input =
        body
        |> Map.merge(query(conn, operation))
        |> Map.merge(params)

      {:ok, input, conn}
    end
  end

  defp body(conn, %{subject: subject}) when subject in ["hook", "channel"] do
    with {:ok, raw, conn} <- raw(conn),
         do: {:ok, %{"body" => raw, "headers" => Map.new(conn.req_headers)}, conn}
  end

  defp body(conn, _operation), do: read_json(conn)

  @doc "Returns the body of `conn`, a JSON object, or `%{}` if it's empty."
  @spec read_json(Plug.Conn.t()) :: {:ok, map(), Plug.Conn.t()} | {:error, Error.t()}
  def read_json(%Plug.Conn{body_params: %Unfetched{}} = conn) do
    conn
    |> raw()
    |> decode()
  end

  def read_json(conn) do
    case BodyReader.get_kept_body(conn) do
      nil -> {:ok, conn.body_params, conn}
      raw -> decode({:ok, raw, conn})
    end
  end

  defp raw(%Plug.Conn{body_params: %Unfetched{}} = conn) do
    case Plug.Conn.read_body(conn, length: @limit) do
      {:ok, raw, conn} ->
        {:ok, raw, conn}

      {:more, _raw, _conn} ->
        {:error, Error.new(:invalid_request, "The body is over 8 MB.")}

      {:error, reason} ->
        {:error, Error.new(:invalid_request, "The body didn't read: #{reason}.")}
    end
  end

  defp raw(conn) do
    case BodyReader.get_kept_body(conn) do
      nil -> {:error, Error.new(:internal, unkept())}
      raw -> {:ok, raw, conn}
    end
  end

  defp unkept,
    do:
      "The body was parsed before Wardrik.HTTP.Endpoint saw it. " <>
        "Give Plug.Parsers body_reader: {Wardrik.HTTP.BodyReader, :read_body, []}."

  defp decode({:ok, "", conn}), do: {:ok, %{}, conn}

  defp decode({:ok, raw, conn}) do
    case JSON.decode(raw) do
      {:ok, %{} = body} -> {:ok, body, conn}
      _not_an_object -> {:error, Error.new(:invalid_request, "The body isn't a JSON object.")}
    end
  end

  defp decode({:error, error}), do: {:error, error}

  defp query(conn, operation) do
    conn.query_string
    |> URI.query_decoder()
    |> Enum.group_by(fn {name, _value} -> name end, fn {_name, value} -> value end)
    |> Map.new(fn {name, values} -> {name, cast_values(values, property(operation, name))} end)
  end

  defp property(%{input: input}, name), do: get_in(input, ["properties", name]) || %{}

  defp cast_values(values, %{"type" => "array"}), do: values

  defp cast_values(values, %{"type" => "integer"}) do
    values
    |> List.last()
    |> integer()
  end

  defp cast_values(values, _property), do: List.last(values)

  defp integer(text) do
    case Integer.parse(text) do
      {number, ""} -> number
      _not_a_number -> text
    end
  end
end
