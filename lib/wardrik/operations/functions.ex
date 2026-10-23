defmodule Wardrik.Operations.Functions do
  @moduledoc false

  alias Wardrik.Operations.Types

  @modules %{"mcp_servers" => "MCPServers"}

  defmacro __using__(prefix: prefix) do
    for operation <- WardrikProtocol.operations(),
        prefix(operation) == prefix,
        function <- functions(operation) do
      function
    end
  end

  @doc "Returns the module whose functions do the operations named `prefix.*`."
  @spec module(String.t()) :: module()
  def module(prefix),
    do: Module.concat(Wardrik, Map.get(@modules, prefix, Macro.camelize(prefix)))

  @doc "Returns the prefix of `operation`'s ID, which names its module."
  @spec prefix(WardrikProtocol.operation()) :: String.t()
  def prefix(%{id: id}), do: id |> parts() |> hd()

  @doc "Returns the name of the function that does `operation`."
  @spec name(WardrikProtocol.operation()) :: atom()
  def name(%{id: id}), do: id |> parts() |> List.last() |> String.to_atom()

  @doc "Returns the names of `operation`'s path parameters, in the order its route takes them."
  @spec path(WardrikProtocol.operation()) :: [String.t()]
  def path(%{path: path}) do
    ~r/\{(\w+)\}/
    |> Regex.scan(path, capture: :all_but_first)
    |> List.flatten()
  end

  defp parts(id), do: String.split(id, ".", parts: 2)

  defp functions(%{stream: true} = operation),
    do: [run(operation), stream(operation)]

  defp functions(operation), do: [run(operation)]

  defp run(operation),
    do: define(operation, name(operation), operation.summary, quote(do: term()), &ran/3)

  defp stream(operation) do
    lead =
      "#{operation.summary}, as a stream of `{%Wardrik.Event{}, cursor}` that reads on and then follows"

    define(
      operation,
      :"stream_#{name(operation)}",
      lead,
      quote(do: {:ok, Enumerable.t()}),
      &streamed/3
    )
  end

  defp ran(id, scope, input) do
    quote do
      with {:ok, output} <- Wardrik.run(unquote(scope), unquote(id), unquote(input)),
           do: Types.decode(unquote(id), output)
    end
  end

  defp streamed(id, scope, input) do
    quote do
      with {:ok, stream} <- Wardrik.stream(unquote(scope), unquote(id), unquote(input)),
           do: {:ok, Stream.map(stream, &Types.event/1)}
    end
  end

  defp define(operation, name, lead, ok, body) do
    parameters = path(operation)
    arguments = Enum.map(parameters, &Macro.var(String.to_atom(&1), __MODULE__))
    types = Enum.map(parameters, fn _parameter -> quote(do: String.t() | struct()) end)
    named = Enum.map(arguments, fn argument -> quote(do: Types.path(unquote(argument))) end)
    path_input = {:%{}, [], Enum.zip(parameters, named)}
    scope = Macro.var(:scope, __MODULE__)
    given = Macro.var(:input, __MODULE__)

    input =
      quote do
        Map.merge(
          Types.encode(unquote(operation.id), unquote(given)),
          unquote(path_input)
        )
      end

    quote do
      @doc unquote(doc(operation, lead))
      @spec unquote(name)(Wardrik.Scope.t(), unquote_splicing(types), term()) ::
              unquote(ok) | :ok | {:error, Wardrik.Error.t()}
      def unquote(name)(unquote(scope), unquote_splicing(arguments), unquote(given) \\ []) do
        unquote(body.(operation.id, scope, input))
      end
    end
  end

  defp doc(operation, lead) do
    route = "`#{String.upcase(operation.method)} #{operation.path}`"

    [lead, operation.description, route]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end
end
