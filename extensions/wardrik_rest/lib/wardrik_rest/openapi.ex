defmodule WardrikRest.OpenAPI do
  @moduledoc """
  Reads OpenAPI 3.0 and 3.1 documents, in JSON or YAML.

      {:ok, suggestions} =
        WardrikRest.API.load(
          {WardrikRest.OpenAPI, path: "priv/apis/catalog-suggestion.openapi.yaml"},
          name: "meta_catalog",
          base_url: "https://ads-api.facebook.com/v27.0/marketing-api",
          auth: %{"OAuthToken__Authorization" => {:credential, "meta"}}
        )

  ## Options

    * `:url` - where the document is. `:req_options` are merged into its request.
    * `:path` - a file holding it.
    * `:document` - the document itself, decoded.

  ## How it reads

    * Each operation is named by its `operationId`, any character but a letter, a digit or `_`
      made `_`, or by its method and path where it has none.
    * Its path, query and header parameters become arguments; cookie parameters are left out.
    * A JSON body's fields become arguments beside them, and a field named like a parameter is
      left out. A body that isn't an object of fields is one argument, `body`. An
      `application/x-www-form-urlencoded` body is sent form-encoded. An operation whose body is
      only some other type, as a file upload, is left out.
    * Its security, or the document's, gives its schemes: `http` `bearer`, `oauth2` and
      `openIdConnect` as a bearer token, and `apiKey` in a header or the query, each by its name
      in `components/securitySchemes`. An alternative needing any other scheme, as HTTP basic,
      is left out, and an operation with none left can't be offered.
    * `components/schemas` become the spec's types. See `WardrikRest.OpenAPI.Schema`.
    * Its `servers` are never read: the API's `:base_url` says where it's reached, with any path
      a server has, as `/v1`.
  """

  @behaviour WardrikRest.Reader

  alias WardrikRest.OpenAPI.Schema
  alias WardrikRest.Operation
  alias WardrikRest.Parameter
  alias WardrikRest.Spec

  @methods %{
    "get" => :get,
    "post" => :post,
    "put" => :put,
    "patch" => :patch,
    "delete" => :delete
  }

  @locations %{"path" => :path, "query" => :query, "header" => :header}
  @description_limit 1_000

  @impl WardrikRest.Reader
  def read(opts) do
    with {:ok, document} <- document(opts), do: spec(document)
  end

  defp document(opts) do
    cond do
      Keyword.has_key?(opts, :document) -> {:ok, opts[:document]}
      Keyword.has_key?(opts, :path) -> file(opts[:path])
      true -> fetch(Keyword.fetch!(opts, :url), Keyword.get(opts, :req_options, []))
    end
  end

  defp file(path) do
    case File.read(path) do
      {:ok, text} -> decoded(text, path)
      {:error, reason} -> {:error, "#{path} can't be read: #{:file.format_error(reason)}."}
    end
  end

  defp fetch(url, req_options) do
    case Req.get(url, [retry: false, decode_body: false] ++ req_options) do
      {:ok, %Req.Response{status: 200, body: text}} -> decoded(text, url)
      {:ok, %Req.Response{status: status}} -> {:error, "#{url} answered #{status}."}
      {:error, reason} -> {:error, "#{url} didn't answer: #{Exception.message(reason)}"}
    end
  end

  # JSON is YAML, but the JSON decoder is the faster and stricter of the two.
  defp decoded(text, where) do
    with {:error, _json} <- JSON.decode(text),
         {:error, _yaml} <- YamlElixir.read_from_string(text) do
      {:error, "#{where} is neither JSON nor YAML."}
    end
  end

  defp spec(%{"openapi" => "3." <> _minor} = document) do
    schemes = schemes(document)

    {:ok,
     %Spec{
       title: text(get_in(document, ["info", "title"])) || "API",
       operations: operations(document, schemes),
       schemes: schemes,
       types: Schema.types(document)
     }}
  end

  defp spec(%{"swagger" => _two}),
    do: {:error, "It's OpenAPI 2 (Swagger); convert it to OpenAPI 3 first."}

  defp spec(_document), do: {:error, "It isn't an OpenAPI 3 document."}

  defp schemes(document) do
    for {name, scheme} <- get_in(document, ["components", "securitySchemes"]) || %{},
        place = place(Schema.resolve(scheme, document)),
        into: %{},
        do: {name, place}
  end

  defp place(%{"type" => "http", "scheme" => scheme}) when is_binary(scheme),
    do: if(String.downcase(scheme) == "bearer", do: :bearer)

  defp place(%{"type" => type}) when type in ["oauth2", "openIdConnect"], do: :bearer
  defp place(%{"type" => "apiKey", "in" => "header", "name" => name}), do: {:header, name}
  defp place(%{"type" => "apiKey", "in" => "query", "name" => name}), do: {:query, name}
  defp place(_other), do: nil

  defp operations(document, schemes) do
    for {path, item} <- Map.get(document, "paths", %{}),
        item = Schema.resolve(item, document),
        {verb, method} <- @methods,
        %{} = operation <- [item[verb]],
        read = operation(document, schemes, {path, item}, {verb, method, operation}),
        read != nil do
      read
    end
    |> unique()
  end

  defp operation(document, schemes, {path, item}, {verb, method, operation}) do
    parameters = parameters(document, item, operation, path)
    taken = MapSet.new(parameters, & &1.name)

    case body(document, operation, taken) do
      {:ok, encoding, body} ->
        %Operation{
          name: name(operation["operationId"], verb, path),
          method: method,
          path: String.trim_leading(text(path), "/"),
          description: description(operation, verb, path),
          parameters: parameters ++ body,
          security: security(operation["security"] || document["security"], schemes),
          encoding: encoding
        }

      :unsupported ->
        nil
    end
  end

  # An operation's parameter replaces its path's of the same name and place.
  defp parameters(document, item, operation, path) do
    (List.wrap(item["parameters"]) ++ List.wrap(operation["parameters"]))
    |> Enum.map(&Schema.resolve(&1, document))
    |> Enum.filter(&Map.has_key?(@locations, &1["in"]))
    |> Enum.reverse()
    |> Enum.uniq_by(&{&1["name"], &1["in"]})
    |> Enum.reverse()
    |> Enum.map(&parameter(&1, document, path))
  end

  defp parameter(param, document, path) do
    location = Map.fetch!(@locations, param["in"])

    schema =
      param
      |> param_schema()
      |> Schema.json(document)
      |> described(param["description"])

    %Parameter{
      name: param["name"],
      in: location,
      schema: schema,
      required: location == :path or param["required"] == true,
      reserved: String.contains?(path, "{+#{param["name"]}}")
    }
  end

  defp param_schema(%{"schema" => schema}), do: schema

  defp param_schema(%{"content" => %{} = content}) do
    case Map.values(content) do
      [%{"schema" => schema} | _more] -> schema
      _none -> %{}
    end
  end

  defp param_schema(_param), do: %{}

  defp body(document, %{"requestBody" => body}, taken) do
    body = Schema.resolve(body, document)
    required = body["required"] == true

    case media(Map.get(body, "content", %{})) do
      {:ok, encoding, schema} -> {:ok, encoding, fields(document, schema, required, taken)}
      :error when required -> :unsupported
      :error -> {:ok, :json, []}
    end
  end

  defp body(_document, _operation, _taken), do: {:ok, :json, []}

  defp media(content) do
    cond do
      json = Enum.find(content, fn {type, _media} -> json?(type) end) ->
        {:ok, :json, schema(json)}

      form = content["application/x-www-form-urlencoded"] ->
        {:ok, :form, form["schema"] || %{}}

      true ->
        :error
    end
  end

  defp json?(type) do
    type =
      type
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()

    type == "application/json" or String.ends_with?(type, "+json")
  end

  defp schema({_type, media}), do: media["schema"] || %{}

  # An object's fields become arguments; anything else is the whole body, as `body`.
  defp fields(document, schema, required, taken) do
    object = Schema.resolve(schema, document)

    case Schema.json(object, document) do
      %{"properties" => %{} = properties} = json when map_size(properties) > 0 ->
        needed = if required, do: Map.get(json, "required", []), else: []

        for {name, field} <- properties, not MapSet.member?(taken, name) do
          %Parameter{name: name, in: :body, schema: field, required: name in needed}
        end

      _other ->
        whole =
          schema
          |> Schema.json(document)
          |> described(object["description"])

        [%Parameter{name: "body", in: :payload, schema: whole, required: required}]
    end
  end

  defp security(nil, _schemes), do: [[]]
  defp security([], _schemes), do: [[]]

  defp security(requirements, schemes) when is_list(requirements) do
    for %{} = requirement <- requirements,
        names = Enum.sort(Map.keys(requirement)),
        Enum.all?(names, &Map.has_key?(schemes, &1)),
        uniq: true,
        do: names
  end

  defp security(_other, _schemes), do: [[]]

  defp name(id, verb, path) do
    raw =
      text(id) ||
        Enum.join([verb | String.split(String.replace(path, ~r/[{}]/, ""), "/", trim: true)], "_")

    safe =
      raw
      |> String.replace(~r/[^A-Za-z0-9_]+/, "_")
      |> String.trim("_")

    case safe do
      "" -> verb
      name -> name
    end
  end

  # Names made from paths, or ids that differ only in punctuation, can repeat.
  defp unique(operations) do
    {unique, _taken} =
      Enum.map_reduce(Enum.sort_by(operations, &{&1.name, &1.path, &1.method}), %{}, fn op,
                                                                                        taken ->
        count = Map.get(taken, op.name, 0)
        name = if count == 0, do: op.name, else: "#{op.name}_#{count + 1}"
        {%{op | name: name}, Map.put(taken, op.name, count + 1)}
      end)

    unique
  end

  defp description(operation, verb, path) do
    [text(operation["summary"]), text(operation["description"])]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join("\n\n")
    |> case do
      "" -> "#{String.upcase(verb)} #{text(path)}"
      written -> cut(written)
    end
  end

  defp cut(text) do
    if String.length(text) > @description_limit,
      do: String.slice(text, 0, @description_limit - 1) <> "…",
      else: text
  end

  defp described(schema, nil), do: schema
  defp described(schema, description), do: Map.put(schema, "description", text(description))

  # YAML block scalars end in a newline, as Meta's `operationId: |` does.
  defp text(value) when is_binary(value), do: String.trim(value)
  defp text(_none), do: nil
end
