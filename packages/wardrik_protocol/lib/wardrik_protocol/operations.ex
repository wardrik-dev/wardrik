defmodule WardrikProtocol.Operations do
  @moduledoc false

  alias WardrikProtocol.Inline

  @methods ~w(get put post patch delete)

  @spec document(Path.t()) :: map()
  def document(dir) do
    dir
    |> Inline.read("openapi")
    |> Inline.whole(dir)
  end

  @spec build(map()) :: [map()]
  def build(document) do
    routes = routes(document)

    for {path, item} <- document["paths"],
        {method, %{"operationId" => _id} = operation} <- item,
        method in @methods do
      document
      |> described(path, method, operation)
      |> conversation(routes, document)
    end
  end

  # A conversation's route is a path item that names its operation, not one of its own.
  defp routes(document) do
    for {path, item} <- document["paths"],
        {method, %{"x-wardrik-operation" => id}} <- item,
        method in @methods,
        into: %{},
        do: {id, path}
  end

  defp conversation(operation, routes, document) do
    case Map.fetch(routes, operation.id) do
      {:ok, path} ->
        parameter = document["components"]["parameters"]["conversation"]

        properties =
          Map.put(operation.input["properties"] || %{}, "conversation", property(parameter))

        %{
          operation
          | conversation: path,
            input: Map.put(operation.input, "properties", properties)
        }

      :error ->
        operation
    end
  end

  defp described(document, path, method, operation) do
    parameters = Enum.map(operation["parameters"] || [], &local(document, &1))
    {status, response} = success(document, operation["responses"])

    %{
      id: operation["operationId"],
      summary: operation["summary"],
      description: operation["description"],
      method: method,
      path: path,
      conversation: nil,
      action: operation["x-wardrik-action"],
      effect: operation["x-wardrik-effect"],
      subject: operation["x-wardrik-subject"],
      parameters: Enum.map(parameters, &%{name: &1["name"], in: &1["in"]}),
      input: input(parameters, request(operation)),
      status: status,
      output: output(operation, response),
      stream: Map.has_key?(response["content"] || %{}, "text/event-stream")
    }
  end

  defp success(document, responses) do
    {status, response} = Enum.find(responses, fn {status, _response} -> status < "300" end)
    {String.to_integer(status), local(document, response)}
  end

  # A hook or a channel takes a request as it came over HTTP, and its input from that.
  defp request(%{"x-wardrik-input" => schema}), do: schema

  defp request(%{
         "requestBody" => %{"content" => %{"application/json" => %{"schema" => schema}}}
       }),
       do: schema

  defp request(_operation), do: %{"type" => "object", "additionalProperties" => false}

  defp output(%{"x-wardrik-output" => schema}, _response), do: schema

  defp output(_operation, response),
    do: get_in(response, ["content", "application/json", "schema"])

  defp input(parameters, body) do
    Enum.reduce(parameters, body, fn parameter, input ->
      schema = property(parameter)

      input
      |> Map.update(
        "properties",
        %{parameter["name"] => schema},
        &Map.put(&1, parameter["name"], schema)
      )
      |> required(parameter)
    end)
  end

  # A schema's own description says what the value is. A path parameter's says how it goes in
  # a URL, which callers of an operation don't need.
  defp property(parameter),
    do: Map.put_new(parameter["schema"], "description", parameter["description"])

  defp required(input, %{"required" => true, "name" => name}),
    do: Map.update(input, "required", [name], &[name | &1])

  defp required(input, _parameter), do: input

  defp local(document, %{"$ref" => "#/" <> pointer}),
    do: get_in(document, String.split(pointer, "/"))

  defp local(_document, value), do: value
end
