defmodule WardrikRest.Discovery do
  @moduledoc """
  Reads Google Discovery documents, the format Google describes its APIs in.

      {:ok, analytics} =
        WardrikRest.API.load(
          {WardrikRest.Discovery,
           url: "https://analyticsdata.googleapis.com/$discovery/rest?version=v1beta"},
          name: "ga4",
          base_url: "https://analyticsdata.googleapis.com/"
        )

  ## Options

    * `:url` - where the document is. `:req_options` are merged into its request.
    * `:document` - the document itself, decoded, as from a file.

  Each method becomes an operation named by its resources, as `properties_runReport`. Its body's
  fields become arguments beside its path and query parameters; a body field named like a
  parameter is left out. A method with scopes signs in with `"oauth2"`, or takes the API key as
  `"key"` where the document has one. Its schemas become the spec's types; see
  `WardrikRest.Discovery.Schema`.
  """

  @behaviour WardrikRest.Reader

  alias WardrikRest.Discovery.Schema
  alias WardrikRest.Operation
  alias WardrikRest.Parameter
  alias WardrikRest.Spec

  @locations %{"path" => :path, "query" => :query}

  @methods %{
    "GET" => :get,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete
  }

  @impl WardrikRest.Reader
  def read(opts) do
    with {:ok, document} <- document(opts), do: spec(document)
  end

  defp document(opts) do
    case Keyword.fetch(opts, :document) do
      {:ok, document} -> {:ok, document}
      :error -> fetch(Keyword.fetch!(opts, :url), Keyword.get(opts, :req_options, []))
    end
  end

  defp fetch(url, req_options) do
    case Req.get(url, [retry: false] ++ req_options) do
      {:ok, %Req.Response{status: 200, body: %{"kind" => "discovery#restDescription"} = body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: 200}} ->
        {:error, "#{url} isn't a Discovery document."}

      {:ok, %Req.Response{status: status}} ->
        {:error, "#{url} answered #{status}."}

      {:error, reason} ->
        {:error, "#{url} didn't answer: #{Exception.message(reason)}"}
    end
  end

  defp spec(%{"kind" => "discovery#restDescription"} = document) do
    parameters = Map.get(document, "parameters", %{})
    keyed = Map.has_key?(parameters, "key")
    schemas = Map.get(document, "schemas", %{})
    names = Schema.names(schemas)
    read = %{document: document, keyed: keyed, schemas: schemas, names: names}

    operations =
      document
      |> methods()
      |> Enum.map(&operation(&1, read))

    {:ok,
     %Spec{
       title: Map.get(document, "title", document["name"]),
       operations: operations,
       schemes: schemes(document, keyed),
       types: Schema.types(schemas)
     }}
  end

  defp spec(_document), do: {:error, "It isn't a Discovery document."}

  defp methods(resource) do
    nested =
      resource
      |> Map.get("resources", %{})
      |> Map.values()

    methods = Map.get(resource, "methods", %{})
    Map.values(methods) ++ Enum.flat_map(nested, &methods/1)
  end

  defp operation(method, %{document: document} = read) do
    params = parameters(method)
    taken = MapSet.new(params, & &1.name)

    name =
      method["id"]
      |> String.split(".")
      |> tl()
      |> Enum.join("_")

    %Operation{
      name: name,
      method: Map.fetch!(@methods, method["httpMethod"]),
      path: Map.get(document, "servicePath", "") <> method["path"],
      description: Map.get(method, "description", method["id"]),
      parameters: params ++ body(method, read, taken),
      security: security(method, read.keyed)
    }
  end

  defp parameters(method) do
    for {name, param} <- Map.get(method, "parameters", %{}) do
      %Parameter{
        name: name,
        in: Map.fetch!(@locations, param["location"]),
        schema: Schema.parameter(param),
        required: param["required"] == true,
        reserved: String.contains?(method["path"], "{+#{name}}")
      }
    end
  end

  defp body(%{"request" => request}, read, taken) do
    for {name, field} <- Schema.fields(request, read.schemas, read.names),
        not MapSet.member?(taken, name),
        do: %Parameter{name: name, in: :body, schema: field}
  end

  defp body(_method, _document, _taken), do: []

  defp security(%{"scopes" => [_scope | _more]}, true), do: [["oauth2"], ["key"]]
  defp security(%{"scopes" => [_scope | _more]}, false), do: [["oauth2"]]
  defp security(_method, _keyed), do: [[]]

  defp schemes(document, keyed) do
    oauth = if get_in(document, ["auth", "oauth2"]), do: [{"oauth2", :bearer}], else: []
    key = if keyed, do: [{"key", {:query, "key"}}], else: []
    Map.new(oauth ++ key)
  end
end
