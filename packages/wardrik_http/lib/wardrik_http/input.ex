defmodule WardrikHTTP.Input do
  @moduledoc false

  alias Plug.Conn.Unfetched
  alias Wardrik.Error
  alias WardrikHTTP.BodyReader

  @limit 8_000_000

  @doc "Returns the input for `operation` from `conn` and the path `params` it was routed by."
  @spec build(Plug.Conn.t(), WardrikProtocol.operation(), map()) ::
          {:ok, map(), Plug.Conn.t()} | {:error, Error.t()}
  def build(conn, operation, params) do
    with {:ok, body, conn} <- body(conn, operation) do
      {:ok, body |> Map.merge(query(conn, operation)) |> Map.merge(params), conn}
    end
  end

  defp body(conn, %{subject: subject}) when subject in ["hook", "channel"] do
    with {:ok, raw, conn} <- raw(conn),
         do: {:ok, %{"body" => raw, "headers" => Map.new(conn.req_headers)}, conn}
  end

  defp body(%Plug.Conn{body_params: %Unfetched{}} = conn, _operation),
    do: conn |> raw() |> decoded()

  defp body(conn, _operation) do
    case BodyReader.kept(conn) do
      nil -> {:ok, conn.body_params, conn}
      raw -> decoded({:ok, raw, conn})
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
    case BodyReader.kept(conn) do
      nil -> {:error, Error.new(:internal, unkept())}
      raw -> {:ok, raw, conn}
    end
  end

  defp unkept,
    do:
      "The body was parsed before WardrikHTTP saw it. " <>
        "Give Plug.Parsers body_reader: {WardrikHTTP.BodyReader, :read_body, []}."

  defp decoded({:ok, "", conn}), do: {:ok, %{}, conn}

  defp decoded({:ok, raw, conn}) do
    case JSON.decode(raw) do
      {:ok, %{} = body} -> {:ok, body, conn}
      _not_an_object -> {:error, Error.new(:invalid_request, "The body isn't a JSON object.")}
    end
  end

  defp decoded({:error, error}), do: {:error, error}

  defp query(conn, operation) do
    conn.query_string
    |> URI.query_decoder()
    |> Enum.group_by(fn {name, _value} -> name end, fn {_name, value} -> value end)
    |> Map.new(fn {name, values} -> {name, typed(values, property(operation, name))} end)
  end

  defp property(%{input: input}, name), do: get_in(input, ["properties", name]) || %{}

  defp typed(values, %{"type" => "array"}), do: values
  defp typed(values, %{"type" => "integer"}), do: values |> List.last() |> integer()
  defp typed(values, _property), do: List.last(values)

  defp integer(text) do
    case Integer.parse(text) do
      {number, ""} -> number
      _not_a_number -> text
    end
  end
end
