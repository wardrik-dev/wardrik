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

  # `agent.decide` names its agent beside its decisions, as `agent.approve` and `agent.deny` do.
  @named ~w(agent.decide)

  @doc """
  Returns whether `operation`'s function takes one keyword list naming its path parameters: one
  with two or more, so their IDs can't be swapped, and `agent.decide`.
  """
  @spec named?(WardrikProtocol.operation()) :: boolean()
  def named?(%{id: id} = operation),
    do: id in @named or match?([_first, _second | _more], path(operation))

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

    {arguments, types, input} =
      if named?(operation),
        do: named(operation, parameters, given),
        else: arguments(operation, parameters, given)

    quote do
      @doc unquote(doc(operation, name, lead, parameters))
      @spec unquote(name)(Wardrik.Scope.t(), unquote_splicing(types)) ::
              unquote(ok) | :ok | {:error, Wardrik.Error.t()}
      def unquote(name)(unquote(scope), unquote_splicing(arguments)) do
        unquote(body.(operation.id, scope, input))
      end
    end
  end

  # Named path parameters are in the input, beside the conversation where there is one.
  defp named(%{id: id}, parameters, given) do
    keys = Enum.map(parameters, &String.to_atom/1)
    input = quote(do: Types.named(unquote(id), unquote(given), unquote(keys)))
    {[given], [quote(do: keyword())], input}
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

  defp doc(operation, name, lead, parameters) do
    route = "`#{String.upcase(operation.method)} #{operation.path}`"

    [
      sentence(lead),
      example(operation, name, parameters),
      operation.description,
      held(operation),
      route
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp sentence(text), do: if(String.ends_with?(text, "."), do: text, else: text <> ".")

  @samples %{
    "agent" => ~s("agt_1"),
    "interrupt" => ~s("call_1"),
    "call" => ~s("call_1"),
    "trigger" => ~s("daily"),
    "secret" => ~s("s3cret"),
    "channel" => ~s("slack"),
    "path" => ~s("events")
  }

  # One call, as a caller writes it, from the operation's path parameters and fields.
  defp example(operation, name, parameters) do
    call = "#{inspect(module(prefix(operation)))}.#{name}"
    "    #{call}(#{Enum.join(["scope" | example_arguments(operation, parameters)], ", ")})"
  end

  defp example_arguments(operation, parameters) do
    if named?(operation),
      do: named_example(operation, parameters),
      else: positional_example(operation, parameters)
  end

  defp named_example(operation, parameters) do
    required = Map.get(operation.input, "required", []) -- parameters

    Enum.map(parameters, &"#{&1}: #{Map.get(@samples, &1, ~s("..."))}") ++
      Enum.map(required, &"#{&1}: #{&1}")
  end

  defp positional_example(operation, parameters) do
    path = Enum.map(parameters, &Map.get(@samples, &1, ~s("...")))
    if Types.fields(operation) == [], do: path, else: path ++ ["input"]
  end

  defp held(%{conversation: nil}), do: nil

  defp held(_operation),
    do: ~s(Add `conversation: "C1"` to act on one of the agent's conversations.)
end
