defmodule Wardrik.Definition do
  @moduledoc """
  A definition says what an agent is and what it may do, as an agent file's frontmatter does. It's
  a map with string keys, as the protocol's `agent_definition` describes it. Build one in Elixir
  with `new!/1`:

      definition =
        Wardrik.Definition.new!(
          model: "anthropic:claude-haiku-4-5",
          instructions: "You watch the incident queue.",
          tools: ["linear/*"],
          policy: [ask: ["linear/*"]]
        )

      Wardrik.Agent.define(scope, "acme/triage", definition)

  Each tool and policy it names is one the Wardrik offers; see `Wardrik.new/1`.
  """

  alias Wardrik.Error
  alias WardrikCore.Principal

  @type t() :: %{String.t() => term()}

  @schema JSV.build!(WardrikProtocol.schema("agent_definition"))
  @unsupported ~w(workspace context retries compaction triggers notify channels)
  @reserved ~w(self/* agents/* workers/*)
  @rounds 25

  @doc "Builds a definition from a keyword list or a map. Raises if it doesn't read."
  @spec new!(keyword() | map()) :: t()
  def new!(fields) do
    definition = stringify(fields)

    case JSV.validate(definition, @schema) do
      {:ok, _valid} -> definition
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  @doc "Returns the options the agent `id` starts with in `wardrik`, as `definition` describes it."
  @spec resolve(Wardrik.t(), String.t(), t()) :: {:ok, keyword()} | {:error, Error.t()}
  def resolve(wardrik, id, definition) do
    with :ok <- supported(definition),
         {:ok, model} <- model(definition),
         {:ok, rounds} <- rounds(definition["max_iterations"]),
         {:ok, capabilities} <- capabilities(wardrik, Map.get(definition, "tools", [])),
         {:ok, policy} <- policy(wardrik, definition["policy"]) do
      {:ok,
       [
         agent_id: id,
         model: model,
         instructions: definition["instructions"],
         capabilities: capabilities,
         principal: principal(id),
         policy: policy,
         timeout: seconds(definition["timeout"]),
         max_rounds: rounds
       ]}
    end
  end

  @doc "Returns the tools `definition` names that offer nothing yet, like an MCP server that's down."
  @spec missing(Wardrik.t(), t()) :: [String.t()]
  def missing(wardrik, definition) do
    for tool <- expanded(wardrik, Map.get(definition, "tools", [])),
        {:ok, server} <- [server(wardrik, tool)],
        WardrikMCP.tools(nil, name: Wardrik.mcp(wardrik), servers: server) == [],
        do: tool
  end

  @doc "Returns how long the agent may have nothing to do before it sleeps, in milliseconds."
  @spec idle_timeout(Wardrik.t(), t()) :: pos_integer() | :infinity
  def idle_timeout(wardrik, definition),
    do: seconds(Map.get(definition, "idle_timeout", wardrik.idle_timeout))

  defp stringify(fields) when is_map(fields),
    do: Map.new(fields, fn {key, value} -> {to_string(key), stringify(value)} end)

  defp stringify([{key, _value} | _rest] = fields) when is_atom(key),
    do: fields |> Map.new() |> stringify()

  defp stringify(values) when is_list(values), do: Enum.map(values, &stringify/1)
  defp stringify(value) when is_boolean(value) or is_nil(value), do: value
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp supported(definition) do
    case Enum.find(@unsupported, &Map.has_key?(definition, &1)) do
      nil ->
        :ok

      key ->
        {:error, Error.new(:not_supported, "A definition's #{key} isn't supported here yet.")}
    end
  end

  defp model(%{"model" => model}), do: {:ok, model}

  defp model(_definition),
    do: {:error, Error.new(:invalid_request, "A definition names a model.")}

  defp rounds(nil), do: {:ok, @rounds}
  defp rounds(rounds) when is_integer(rounds), do: {:ok, rounds}

  defp rounds("infinity"),
    do:
      {:error, Error.new(:not_supported, "max_iterations of infinity isn't supported here yet.")}

  defp capabilities(wardrik, tools) do
    named = Enum.map(expanded(wardrik, tools), &named(wardrik, &1))

    case Enum.find(named, &match?({:error, _error}, &1)) do
      nil -> {:ok, entries(wardrik, named)}
      error -> error
    end
  end

  defp expanded(wardrik, tools), do: Enum.flat_map(tools, &expand(wardrik, &1))

  defp expand(wardrik, "*"),
    do: Map.keys(wardrik.capabilities) ++ Enum.map(servers(wardrik), &"#{&1}/*")

  defp expand(_wardrik, tool), do: [tool]

  defp named(_wardrik, tool) when tool in @reserved,
    do: {:error, Error.new(:not_supported, "#{tool} isn't supported here yet.")}

  defp named(wardrik, tool) do
    with :error <- capability(wardrik, tool),
         :error <- server(wardrik, tool) do
      {:error, Error.new(:invalid_request, "There's no tool or MCP server #{tool} here.")}
    end
  end

  defp capability(wardrik, tool) do
    with {:ok, entry} <- Map.fetch(wardrik.capabilities, tool), do: {:capability, entry}
  end

  defp server(wardrik, tool) do
    case String.split(tool, "/") do
      [name, "*"] ->
        Enum.find_value(servers(wardrik), :error, &(Atom.to_string(&1) == name && {:ok, &1}))

      _not_a_server ->
        :error
    end
  end

  defp servers(%Wardrik{mcp: nil}), do: []
  defp servers(%Wardrik{mcp: mcp}), do: Keyword.keys(mcp)

  defp entries(wardrik, named) do
    capabilities = for {:capability, entry} <- named, uniq: true, do: entry

    case for({:ok, server} <- named, uniq: true, do: server) do
      [] -> capabilities
      servers -> capabilities ++ [{WardrikMCP, name: Wardrik.mcp(wardrik), servers: servers}]
    end
  end

  defp policy(_wardrik, nil), do: {:ok, nil}

  defp policy(wardrik, name) when is_binary(name) do
    case Map.fetch(wardrik.policies, name) do
      {:ok, policy} -> {:ok, policy}
      :error -> {:error, Error.new(:invalid_request, "There's no policy #{name} here.")}
    end
  end

  defp policy(_wardrik, rules) do
    case WardrikPolicy.decode(rules) do
      {:ok, policy} ->
        {:ok, policy}

      {:error, message} ->
        {:error, Error.new(:invalid_request, "The policy doesn't read: #{message}")}
    end
  end

  defp principal(id) do
    case String.split(id, "/") do
      [org, "@" <> _user = user, _name] -> %Principal{id: org <> "/" <> user}
      [org, _name] -> %Principal{id: org}
    end
  end

  defp seconds(nil), do: :infinity
  defp seconds("infinity"), do: :infinity
  defp seconds(:infinity), do: :infinity
  defp seconds(seconds), do: round(seconds * 1000)
end
