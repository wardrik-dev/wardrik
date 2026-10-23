defmodule Wardrik.Operations.Functions do
  @moduledoc false

  defmacro __using__(prefix: prefix) do
    for operation <- WardrikProtocol.operations(),
        prefix(operation) == prefix,
        function <- functions(operation) do
      function
    end
  end

  @doc "Returns the module whose functions do the operations named `prefix.*`."
  @spec module(String.t()) :: module()
  def module(prefix), do: Module.concat(Wardrik, Macro.camelize(prefix))

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

  defp run(operation) do
    define(operation, name(operation), :run, quote(do: {:ok, term()}))
  end

  defp stream(operation) do
    define(operation, :"stream_#{name(operation)}", :stream, quote(do: {:ok, Enumerable.t()}))
  end

  defp define(operation, name, call, ok) do
    parameters = path(operation)
    arguments = Enum.map(parameters, &Macro.var(String.to_atom(&1), __MODULE__))
    types = Enum.map(parameters, fn _parameter -> quote(do: String.t()) end)
    path_input = {:%{}, [], Enum.zip(parameters, arguments)}

    quote do
      @doc unquote(doc(operation, call))
      @spec unquote(name)(Wardrik.Scope.t(), unquote_splicing(types), map()) ::
              unquote(ok) | {:error, Wardrik.Error.t()}
      def unquote(name)(scope, unquote_splicing(arguments), input \\ %{}) do
        Wardrik.unquote(call)(scope, unquote(operation.id), Map.merge(input, unquote(path_input)))
      end
    end
  end

  defp doc(operation, call) do
    route = "`#{String.upcase(operation.method)} #{operation.path}`"

    [lead(operation, call), operation.description, route]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp lead(operation, :run), do: operation.summary

  defp lead(operation, :stream),
    do: "#{operation.summary}, as a stream of `{event, cursor}` that reads on and then follows"
end
