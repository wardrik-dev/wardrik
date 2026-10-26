defmodule Wardrik.Definition do
  @moduledoc """
  A definition says what an agent is and what it may do, as an agent file's frontmatter does, with
  the keys the protocol's `agent_definition` gives it. Build one with `new!/1`:

      definition =
        Wardrik.Definition.new!(
          model: "anthropic:claude-haiku-4-5",
          instructions: "You watch the incident queue.",
          tools: ["linear/*"],
          policy: [ask: ["linear/*"]]
        )

      Wardrik.Agent.define(scope, "acme/triage", definition)
      #=> {:ok, %Wardrik.Agent{id: "acme/triage", status: :idle, ...}}

  Each tool and policy it names is one the Wardrik offers; see `Wardrik.start_link/1`. `policy`,
  `workspace`, `context`, `retries`, `compaction` and `notify` are kept as the protocol writes them,
  and each of `triggers` is a `Wardrik.Trigger`.
  """

  use Wardrik.Type,
    schema: ["agent_definition"],
    fields: [
      display_name: "display_name",
      description: "description",
      instructions: "instructions",
      model: "model",
      tools: "tools",
      workspace: "workspace",
      context: "context",
      policy: "policy",
      timeout: "timeout",
      idle_timeout: {"idle_timeout", :infinity},
      max_iterations: {"max_iterations", :infinity},
      retries: "retries",
      compaction: "compaction",
      triggers: {"triggers", [Wardrik.Trigger]},
      notify: "notify",
      channels: "channels"
    ]

  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Type
  alias WardrikCore.Principal

  @schema JSV.build!(WardrikProtocol.schema("agent_definition"))
  @unsupported ~w(workspace context retries compaction notify)
  @reserved ~w(self/* agents/*)
  @rounds 25

  @doc "Builds a definition from a keyword list or a map. Raises if it doesn't read."
  @spec new!(keyword() | map()) :: t()
  def new!(fields) do
    json = Type.json(fields)

    case JSV.validate(json, @schema) do
      {:ok, _valid} -> from_json(json)
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  @doc "Returns the options the agent `id` starts with in `wardrik`, as the JSON `definition` describes it."
  @spec resolve(Wardrik.t(), String.t(), map()) :: {:ok, keyword()} | {:error, Error.t()}
  def resolve(wardrik, id, definition) do
    with :ok <- supported(definition),
         :ok <- triggers(Map.get(definition, "triggers", [])),
         {:ok, model} <- model(definition),
         {:ok, rounds} <- rounds(definition["max_iterations"]),
         {:ok, capabilities} <- capabilities(wardrik, Map.get(definition, "tools", [])),
         :ok <- channels(wardrik, Map.get(definition, "channels", [])),
         {:ok, policy} <- policy(wardrik, definition["policy"]),
         {:ok, boundary} <-
           policy(wardrik, Wardrik.Definitions.boundary(wardrik, AgentID.agent(id))) do
      {:ok,
       [
         agent_id: id,
         model: model,
         instructions: definition["instructions"],
         capabilities: capabilities,
         principal: principal(id),
         policy: Enum.reject([boundary, policy], &is_nil/1),
         timeout: seconds(definition["timeout"]),
         max_rounds: rounds
       ]}
    end
  end

  @doc "Returns the definition with each of its triggers named, `trigger-1` and so on by its place unless it says."
  @spec named(map()) :: map()
  def named(%{"triggers" => triggers} = definition) do
    named =
      triggers
      |> Enum.with_index(1)
      |> Enum.map(fn {trigger, index} -> Map.put_new(trigger, "name", "trigger-#{index}") end)

    %{definition | "triggers" => named}
  end

  def named(definition), do: definition

  @doc "Returns `:ok` if the trigger `fields` describe reads, and is one Wardrik supports."
  @spec trigger(map(), pos_integer()) :: :ok | {:error, Error.t()}
  def trigger(%{"prompt_file" => _file}, _index),
    do: {:error, Error.new(:not_supported, "A trigger's prompt_file isn't supported here yet.")}

  def trigger(fields, index) do
    case WardrikTriggers.Trigger.decode(fields, index) do
      {:ok, _trigger} -> :ok
      {:error, why} -> {:error, Error.new(:invalid_request, "A trigger doesn't read: #{why}.")}
    end
  end

  @doc "Returns who the agent `id` acts as: its user, as `acme/@maria`, or its org, as `acme`."
  @spec principal(String.t()) :: Principal.t()
  def principal(id) do
    {:ok, %AgentID{owner: owner}} = AgentID.parse(id)
    %Principal{id: owner}
  end

  @doc """
  Returns the servers the agent `id`'s definition names that offer nothing yet: one its owner hasn't
  added, or one that's down.
  """
  @spec missing(Wardrik.t(), String.t(), map()) :: [String.t()]
  def missing(wardrik, id, definition) do
    mcp = Wardrik.mcp(wardrik)

    for tool <- expanded(wardrik, Map.get(definition, "tools", [])),
        {:server, name} <- [named(wardrik, tool)],
        WardrikMCP.tools(nil,
          name: mcp,
          servers: Wardrik.MCPTools.picked(mcp, id, names: [name])
        ) == [],
        do: tool
  end

  @doc "Returns how long the agent may have nothing to do before it sleeps, in milliseconds."
  @spec idle_timeout(Wardrik.t(), map()) :: pos_integer() | :infinity
  def idle_timeout(wardrik, definition),
    do: seconds(Map.get(definition, "idle_timeout", wardrik.idle_timeout))

  defp supported(definition) do
    case Enum.find(@unsupported, &Map.has_key?(definition, &1)) do
      nil ->
        :ok

      key ->
        {:error, Error.new(:not_supported, "A definition's #{key} isn't supported here yet.")}
    end
  end

  defp triggers(triggers) do
    triggers
    |> Enum.with_index(1)
    |> Enum.map(fn {fields, index} -> trigger(fields, index) end)
    |> Enum.find(:ok, &match?({:error, _error}, &1))
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
    do:
      Map.keys(wardrik.capabilities) ++
        Enum.map(started(wardrik), &"#{&1}/*") ++ ["servers/*", "workers/*"]

  defp expand(_wardrik, tool), do: [tool]

  defp named(_wardrik, tool) when tool in @reserved,
    do: {:error, Error.new(:not_supported, "#{tool} isn't supported here yet.")}

  defp named(_wardrik, "servers/*"), do: :all_servers
  defp named(wardrik, "workers/*"), do: {:capability, {Wardrik.Workers, wardrik: wardrik.name}}

  defp named(wardrik, tool) do
    case {Map.fetch(wardrik.capabilities, tool), String.split(tool, "/")} do
      {{:ok, entry}, _parts} -> {:capability, entry}
      {:error, [name, "*"]} when name != "" -> {:server, name}
      {:error, _parts} -> {:error, Error.new(:invalid_request, "There's no tool #{tool} here.")}
    end
  end

  defp started(%Wardrik{mcp: nil}), do: []
  defp started(%Wardrik{mcp: mcp}), do: Enum.map(Keyword.keys(mcp), &to_string/1)

  defp entries(wardrik, named) do
    capabilities = for {:capability, entry} <- named, uniq: true, do: entry
    servers = for {:server, name} <- named, uniq: true, do: name
    all = :all_servers in named

    if servers == [] and not all,
      do: capabilities,
      else:
        capabilities ++
          [{Wardrik.MCPTools, mcp: Wardrik.mcp(wardrik), names: servers, all: all}]
  end

  defp channels(wardrik, names) do
    case Enum.reject(names, &Map.has_key?(wardrik.channels, &1)) do
      [] -> :ok
      [name | _rest] -> {:error, Error.new(:invalid_request, "There's no channel #{name} here.")}
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

  defp seconds(nil), do: :infinity
  defp seconds("infinity"), do: :infinity
  defp seconds(:infinity), do: :infinity
  defp seconds(seconds), do: round(seconds * 1000)
end
