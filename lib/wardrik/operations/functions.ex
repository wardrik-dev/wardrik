defmodule Wardrik.Operations.Functions do
  @moduledoc false

  alias Wardrik.Operations.Types

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
    do: Module.concat(Wardrik, Macro.camelize(prefix))

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
      "#{operation.summary}, then follow new events as they arrive. Returns `{:ok, stream}` of `{%Wardrik.Event{}, cursor}` pairs."

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
      with {:ok, output} <- Wardrik.Scope.run(unquote(scope), unquote(id), unquote(input)),
           do: Types.decode(unquote(id), output)
    end
  end

  defp streamed(id, scope, input) do
    quote do
      with {:ok, stream} <- Wardrik.Scope.stream(unquote(scope), unquote(id), unquote(input)),
           do: {:ok, Stream.map(stream, &Types.event/1)}
    end
  end

  defp define(operation, name, lead, ok, body) do
    parameters = path(operation)
    scope = Macro.var(:scope, __MODULE__)
    given = Macro.var(:input, __MODULE__)
    {arguments, types, input} = arguments(operation, parameters, given)

    quote do
      @doc unquote(doc(operation, lead, parameters))
      @spec unquote(name)(Wardrik.Scope.t(), unquote_splicing(types)) ::
              unquote(ok) | :ok | {:error, Wardrik.Error.t()}
      def unquote(name)(unquote(scope), unquote_splicing(arguments)) do
        unquote(body.(operation.id, scope, input))
      end
    end
  end

  # Two or more path parameters are named in the input, so their IDs can't be swapped.
  defp arguments(%{id: id} = operation, [_first, _second | _more] = parameters, given) do
    keys = Enum.map(parameters, &String.to_atom/1)
    input = quote(do: Types.named(unquote(id), unquote(given), unquote(keys)))
    conversation({[given], [quote(do: keyword())], input}, operation)
  end

  defp arguments(%{id: id} = operation, parameters, given) do
    arguments = Enum.map(parameters, &Macro.var(String.to_atom(&1), __MODULE__))
    types = Enum.map(parameters, fn _parameter -> quote(do: String.t() | struct()) end)
    named = Enum.map(arguments, fn argument -> quote(do: Types.path(unquote(argument))) end)
    path_input = {:%{}, [], Enum.zip(parameters, named)}

    input =
      quote do
        unquote(id)
        |> Types.encode(unquote(given))
        |> then(&Types.checked(unquote(id), &1))
        |> Map.merge(unquote(path_input))
      end

    {arguments ++ [quote(do: unquote(given) \\ [])], types ++ [quote(do: term())], input}
    |> fieldless(operation, path_input)
    |> conversation(operation)
  end

  # An operation with no input of its own takes none: only its path parameters, and opts.
  defp fieldless({arguments, types, input}, operation, path_input) do
    if Types.fields(operation) == [],
      do: {Enum.drop(arguments, -1), Enum.drop(types, -1), path_input},
      else: {arguments, types, input}
  end

  # An operation on a conversation takes it in `opts`, whatever form its input takes.
  defp conversation(arguments, %{conversation: nil}), do: arguments

  defp conversation({arguments, types, input}, _operation) do
    opts = Macro.var(:opts, __MODULE__)

    {arguments ++ [quote(do: unquote(opts) \\ [])], types ++ [quote(do: keyword())],
     quote(do: Types.conversation(unquote(input), unquote(opts)))}
  end

  defp doc(operation, lead, parameters) do
    route = "`#{String.upcase(operation.method)} #{operation.path}`"

    [lead, operation.description, named(parameters), held(operation, parameters), route]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp named([_first, _second | _more] = parameters) do
    {last, keys} = parameters |> Enum.map(&"`:#{&1}`") |> List.pop_at(-1)
    "Name #{Enum.join(keys, ", ")} and #{last} in `input`."
  end

  defp named(_parameters), do: nil

  defp held(%{conversation: nil}, _parameters), do: nil

  defp held(_operation, _parameters),
    do: "Give `conversation: id` in `opts` to act on one of the agent's conversations."
end
