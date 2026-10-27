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
  alias Wardrik.Orgs
  alias Wardrik.Type
  alias WardrikCore.Principal

  @schema JSV.build!(WardrikProtocol.schema("agent_definition"))
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

  @doc """
  Returns the options the agent `id` starts with in `wardrik`, as the JSON `definition` describes
  it, under its org's settings.
  """
  @spec resolve(Wardrik.t(), String.t(), map()) :: {:ok, keyword()} | {:error, Error.t()}
  def resolve(wardrik, id, definition) do
    org = Orgs.org(id)

    with {:ok, settings} <- Orgs.settings(wardrik, org),
         {:ok, opts} <- resolved(Orgs.within(wardrik, settings), id, definition),
         do: {:ok, Orgs.hold(opts, wardrik, org, settings)}
  end

  defp resolved(wardrik, id, definition) do
    definition = Map.merge(wardrik.defaults, definition)

    with :ok <- triggers(wardrik, definition),
         {:ok, model} <- model(definition),
         {:ok, rounds} <- rounds(definition["max_iterations"]),
         {:ok, capabilities} <- capabilities(wardrik, Map.get(definition, "tools", [])),
         {:ok, workspace} <-
           Wardrik.Workspaces.resolve(wardrik, id, definition, files?(wardrik, definition)),
         :ok <- channels(wardrik, Map.get(definition, "channels", [])),
         :ok <- Wardrik.Notify.check(wardrik, AgentID.agent(id), definition),
         {:ok, policy} <- policy(wardrik, definition["policy"]),
         policy = gating(policy),
         {:ok, boundary} <-
           policy(wardrik, Wardrik.Definitions.boundary(wardrik, AgentID.agent(id))) do
      {:ok,
       [
         agent_id: id,
         model: model,
         instructions: definition["instructions"],
         capabilities: capabilities ++ workspace[:capabilities],
         middleware: workspace[:middleware] ++ compaction(definition["compaction"]),
         retries: retries(definition["retries"]),
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

  @doc "Returns `:ok` if the trigger `fields` describe reads, and the agent `definition` can follow it."
  @spec trigger(Wardrik.t(), map(), map(), pos_integer()) :: :ok | {:error, Error.t()}
  def trigger(wardrik, definition, fields, index) do
    with :ok <- prompted(fields, files?(wardrik, Map.merge(wardrik.defaults, definition))) do
      case WardrikTriggers.Trigger.decode(fields, index) do
        {:ok, _trigger} -> :ok
        {:error, why} -> {:error, Error.new(:invalid_request, "A trigger doesn't read: #{why}.")}
      end
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

  @doc "Returns how long the agent `id` may have nothing to do before it sleeps, in milliseconds."
  @spec idle_timeout(Wardrik.t(), String.t(), map()) :: pos_integer() | :infinity
  def idle_timeout(wardrik, id, definition) do
    defaults = Orgs.defaults(wardrik, id)

    seconds(
      Map.get(definition, "idle_timeout", Map.get(defaults, "idle_timeout", wardrik.idle_timeout))
    )
  end

  defp triggers(wardrik, definition) do
    definition
    |> Map.get("triggers", [])
    |> Enum.with_index(1)
    |> Enum.map(fn {fields, index} -> trigger(wardrik, definition, fields, index) end)
    |> Enum.find(:ok, &match?({:error, _error}, &1))
  end

  defp prompted(%{"prompt_file" => _file, "prompt" => _prompt}, _files?),
    do:
      {:error, Error.new(:invalid_request, "A trigger has a prompt or a prompt_file, not both.")}

  defp prompted(%{"prompt_file" => _file}, false),
    do:
      {:error,
       Error.new(
         :invalid_request,
         "A trigger's prompt_file names a file, and tools names no files to read it with."
       )}

  defp prompted(%{"prompt_file" => file}, true) do
    case WardrikWorkspace.Path.normalize(file) do
      {:ok, _path} -> :ok
      {:error, why} -> {:error, Error.new(:invalid_request, "A trigger's prompt_file: #{why}.")}
    end
  end

  defp prompted(_fields, _files?), do: :ok

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
        Enum.map(started(wardrik), &"#{&1}/*") ++ ["servers/*", "workers/*", "files"]

  defp expand(_wardrik, tool), do: [tool]

  defp named(_wardrik, "servers/*"), do: :all_servers
  defp named(_wardrik, "files"), do: :files

  defp named(wardrik, "agents/*"),
    do: {:capability, {Wardrik.AgentTools, wardrik: wardrik.name, reach: :agents}}

  defp named(wardrik, "self/*"),
    do: {:capability, {Wardrik.AgentTools, wardrik: wardrik.name, reach: :self}}

  defp named(wardrik, "workers/*"), do: {:capability, {Wardrik.Workers, wardrik: wardrik.name}}

  defp named(wardrik, tool) do
    case {Map.fetch(wardrik.capabilities, tool), String.split(tool, "/")} do
      {{:ok, entry}, _parts} -> {:capability, entry}
      {:error, [name, "*"]} when name != "" -> {:server, name}
      {:error, _parts} -> {:error, Error.new(:invalid_request, "There's no tool #{tool} here.")}
    end
  end

  defp started(%Wardrik{mcp: nil}), do: []
  defp started(%Wardrik{mcp: mcp}), do: Enum.map(mcp, fn {name, _opts} -> to_string(name) end)

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

  defp files?(wardrik, definition),
    do: "files" in expanded(wardrik, Map.get(definition, "tools", []))

  defp retries(nil), do: []
  defp retries(settings), do: for({key, value} <- settings, do: retry_setting(key, value))

  defp retry_setting("attempts", attempts), do: {:attempts, attempts}
  defp retry_setting("max_wait", seconds), do: {:max_wait, :timer.seconds(seconds)}
  defp retry_setting("on_exhausted", "ask"), do: {:on_exhausted, :ask}
  defp retry_setting("on_exhausted", "fail"), do: {:on_exhausted, :fail}

  defp compaction(false), do: []
  defp compaction(nil), do: [{Wardrik.Compaction, []}]

  defp compaction(settings),
    do: [{Wardrik.Compaction, for({key, value} <- settings, do: {compaction_key(key), value})}]

  defp compaction_key("at"), do: :at
  defp compaction_key("keep"), do: :keep
  defp compaction_key("window"), do: :window

  defp gating(nil), do: WardrikPolicy.new!(default: [gated: :ask])

  defp gating(%WardrikPolicy{by_annotation: by_annotation} = policy),
    do: %{policy | by_annotation: Map.put_new(by_annotation, "gated", :ask)}

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
