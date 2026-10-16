defmodule WardrikHTTP.OpenAPI do
  @moduledoc """
  `wardrik_protocol`'s `openapi.json`, read for the suite: the operation a
  request is, and whether an answer is one it lists.

  `attach/1` adds a response step to a `Req` client that checks every answer
  it receives: its status is one the operation lists, and its JSON body is
  what the schema for that status describes. A request to no path the
  document names is left alone, as the router answers it as no route.
  """

  import ExUnit.Assertions

  @methods ~w(get put post delete)

  @doc "The document, read once."
  @spec document() :: map()
  def document do
    case :persistent_term.get(__MODULE__, nil) do
      nil ->
        document = WardrikProtocol.openapi() |> File.read!() |> JSON.decode!()
        :persistent_term.put(__MODULE__, document)
        document

      document ->
        document
    end
  end

  @doc "Every path the document names, with the methods its operations answer."
  @spec routes() :: [{String.t(), [String.t()]}]
  def routes do
    for {path, item} <- document()["paths"],
        do: {path, for(method <- @methods, Map.has_key?(item, method), do: method)}
  end

  @doc "`client`, checking every answer it receives against the document."
  @spec attach(Req.Request.t()) :: Req.Request.t()
  def attach(%Req.Request{} = client),
    do: Req.Request.append_response_steps(client, openapi: &check/1)

  defp check({request, response}) do
    method = request.method |> Atom.to_string() |> String.downcase()
    path = URI.decode(request.url.path || "")

    case operation(method, path) do
      :no_path -> :ok
      :no_method -> no_route!(method, path, response)
      {template, operation} -> answered!(method, template, operation, response)
    end

    {request, response}
  end

  # The template of the path `path` matches, and the operation of `method`
  # there.
  defp operation(method, path) do
    case Enum.find(document()["paths"], fn {template, _item} -> matches?(template, path) end) do
      nil ->
        :no_path

      {template, item} ->
        case item[method] do
          nil -> :no_method
          operation -> {template, operation}
        end
    end
  end

  defp matches?(template, path) do
    pattern =
      template
      |> Regex.escape()
      |> String.replace(~r/\\\{[a-z_]+\\\}/, "[^/]+")

    Regex.match?(~r/\A#{pattern}\z/, path)
  end

  defp no_route!(method, path, response) do
    assert response.status == 404,
           "#{String.upcase(method)} #{path} is no operation of openapi.json, " <>
             "and answered #{response.status}"
  end

  # Any route answers 500 where something went wrong, and 503 where
  # credentials cannot be checked.
  defp answered!(_method, _template, _operation, %{status: status}) when status in [500, 503],
    do: :ok

  defp answered!(method, template, operation, response) do
    status = Integer.to_string(response.status)
    named = "#{String.upcase(method)} #{template} #{status}"
    json? = Enum.any?(Req.Response.get_header(response, "content-type"), &(&1 =~ "json"))
    schema = get_in(answer!(operation, status, named), ["content", "application/json", "schema"])

    if json? and schema, do: valid!(response.body, schema, named)
  end

  # The answer `operation` lists for `status`, as its component where it
  # names one.
  defp answer!(operation, status, named) do
    case operation["responses"][status] do
      %{"$ref" => "#/components/responses/" <> name} ->
        document()["components"]["responses"][name]

      nil ->
        flunk("#{named} is not an answer openapi.json lists")

      answer ->
        answer
    end
  end

  defp valid!(body, schema, named) when is_map(body) do
    root = JSV.build!(root(schema), resolver: WardrikProtocol.Resolver)

    case JSV.validate(body, root) do
      {:ok, _valid} ->
        :ok

      {:error, error} ->
        flunk(
          "#{named} is not what openapi.json says it answers: " <>
            inspect(JSV.normalize_error(error), pretty: true, limit: :infinity)
        )
    end
  end

  defp valid!(body, _schema, named),
    do: flunk("#{named} answered #{inspect(body)}, where openapi.json says JSON")

  # A schema JSV builds: the document's own schemas as `$defs`, and its
  # references to the protocol's files by their `$id`.
  defp root(schema) do
    %{
      "$schema" => "https://json-schema.org/draft/2020-12/schema",
      "$defs" => refs(document()["components"]["schemas"]),
      "$ref" => "#/$defs/answer"
    }
    |> put_in(["$defs", "answer"], refs(schema))
  end

  defp refs(%{"$ref" => "#/components/schemas/" <> name} = schema),
    do: %{schema | "$ref" => "#/$defs/" <> name}

  defp refs(%{"$ref" => "v1/" <> file} = schema) do
    [name | fragment] = String.split(file, "#", parts: 2)

    %{
      schema
      | "$ref" =>
          "urn:wardrik:schema:v1:" <> Path.rootname(name) <> Enum.map_join(fragment, &("#" <> &1))
    }
  end

  defp refs(map) when is_map(map), do: Map.new(map, fn {key, value} -> {key, refs(value)} end)
  defp refs(list) when is_list(list), do: Enum.map(list, &refs/1)
  defp refs(value), do: value
end
