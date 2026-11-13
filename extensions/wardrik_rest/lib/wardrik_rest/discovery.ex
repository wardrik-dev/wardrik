defmodule WardrikRest.Discovery do
  @moduledoc """
  A Google Discovery document, the format Google describes its APIs in.

      {:ok, analytics} =
        WardrikRest.Discovery.fetch("https://analyticsdata.googleapis.com/$discovery/rest?version=v1beta")

  Or from a file: `%WardrikRest.Discovery{document: path |> File.read!() |> JSON.decode!()}`.

  Each method becomes an operation named by its resources, as `properties_runReport`. Its body's
  fields become arguments beside its path and query parameters; a body field named like a
  parameter is left out. A method with scopes signs in with `"oauth2"`, or takes the API key as
  `"key"` where the document has one. Its schemas become the spec's types; see
  `WardrikRest.Discovery.Schema`.
  """

  @enforce_keys [:document]
  defstruct [:document]

  @type t() :: %__MODULE__{document: map()}

  @doc """
  Fetches the document at `url`. `:req_options` are merged into the request.

  Returns `{:error, reason}` if it can't be fetched or isn't a Discovery document.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def fetch(url, opts \\ []) do
    options = [retry: false] ++ Keyword.get(opts, :req_options, [])

    case Req.get(url, options) do
      {:ok, %Req.Response{status: 200, body: %{"kind" => "discovery#restDescription"} = body}} ->
        {:ok, %__MODULE__{document: body}}

      {:ok, %Req.Response{status: 200}} ->
        {:error, "#{url} isn't a Discovery document."}

      {:ok, %Req.Response{status: status}} ->
        {:error, "#{url} answered #{status}."}

      {:error, reason} ->
        {:error, "#{url} didn't answer: #{Exception.message(reason)}"}
    end
  end

  defimpl WardrikRest.Reader do
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

    def read(%{document: %{"kind" => "discovery#restDescription"} = document}) do
      keyed = Map.has_key?(Map.get(document, "parameters", %{}), "key")
      schemas = Map.get(document, "schemas", %{})
      names = Schema.names(schemas)
      read = %{document: document, keyed: keyed, schemas: schemas, names: names}

      {:ok,
       %Spec{
         title: Map.get(document, "title", document["name"]),
         operations: document |> methods() |> Enum.map(&operation(&1, read)),
         schemes: schemes(document, keyed),
         types: Schema.types(schemas)
       }}
    end

    def read(_discovery), do: {:error, "It isn't a Discovery document."}

    defp methods(resource) do
      Map.values(Map.get(resource, "methods", %{})) ++
        Enum.flat_map(Map.values(Map.get(resource, "resources", %{})), &methods/1)
    end

    defp operation(method, %{document: document} = read) do
      params = parameters(method)
      taken = MapSet.new(params, & &1.name)

      %Operation{
        name: method["id"] |> String.split(".") |> tl() |> Enum.join("_"),
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
end
