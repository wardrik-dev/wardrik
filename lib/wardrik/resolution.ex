defmodule Wardrik.Resolution do
  @moduledoc false

  alias Wardrik.AgentID
  alias Wardrik.Error
  alias Wardrik.Operations.Running
  alias Wardrik.Resolved
  alias Wardrik.Resolver
  alias Wardrik.Setup

  @rounds 25

  @doc "Returns the agent `id`'s start options, from its JSON `definition` and what it resolves to."
  @spec resolve(Wardrik.t(), String.t(), map()) :: {:ok, keyword()} | {:error, Error.t()}
  def resolve(wardrik, id, definition) do
    with {:ok, resolved} <- Resolver.resolve(wardrik, id, definition),
         {:ok, opts} <- resolved(within(wardrik, resolved), id, definition, resolved),
         do: {:ok, hold(opts, resolved)}
  end

  @doc "Returns `opts` held to the policy and middleware the agent resolved to."
  @spec hold(keyword(), Resolved.t()) :: keyword()
  def hold(opts, %Resolved{policy: policy, middleware: middleware}) do
    held = List.wrap(policy)

    opts
    |> Keyword.update(:policy, held, &(held ++ Setup.policies(&1)))
    |> Keyword.update(:middleware, middleware, &(&1 ++ middleware))
  end

  defp within(wardrik, %Resolved{policies: policies, defaults: defaults}),
    do: %{
      wardrik
      | policies: Map.merge(wardrik.policies, policies),
        defaults: Map.merge(wardrik.defaults, defaults)
    }

  defp resolved(wardrik, id, definition, resolved) do
    definition = Map.merge(wardrik.defaults, definition)
    servers = resolved.servers

    with :ok <- triggers(definition),
         {:ok, model} <- model(definition),
         {:ok, capabilities} <- capabilities(wardrik, servers, definition),
         {:ok, workspace} <-
           Wardrik.Workspaces.resolve(wardrik, id, definition, files?(definition)),
         :ok <- channels(wardrik, Map.get(definition, "channels", [])),
         :ok <- Wardrik.Notify.check(wardrik, resolved.notify, definition),
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
         principal: resolved.principal,
         policy: Enum.reject([boundary, policy], &is_nil/1),
         timeout: seconds(definition["timeout"]),
         max_rounds: rounds(definition["max_iterations"])
       ]}
    end
  end

  @doc "Refreshes each awake agent of `ids`, or every awake one. Returns a line for each failure."
  @spec refresh(Wardrik.t(), [String.t()] | :all) :: [String.t()]
  def refresh(wardrik, ids) do
    for id <- refreshing(wardrik, ids),
        Running.whereis(wardrik, id) != nil,
        {:error, error} <- [refreshed(wardrik, id)],
        do: "#{id}: #{error.message}"
  end

  defp refreshing(wardrik, :all), do: Wardrik.Definitions.ids(wardrik)
  defp refreshing(_wardrik, ids), do: ids

  defp refreshed(wardrik, id) do
    with {:ok, definition} <- Running.definition(wardrik, id),
         {:ok, opts} <- resolve(wardrik, id, definition),
         do: Running.bring(wardrik, opts)
  end

  @doc "Returns `:ok` if the trigger in `fields` is valid for the agent `definition`."
  @spec trigger(Wardrik.t(), map(), map(), pos_integer()) :: :ok | {:error, Error.t()}
  def trigger(wardrik, definition, fields, index),
    do: trigger(fields, index, files?(Map.merge(wardrik.defaults, definition)))

  defp trigger(fields, index, files?) do
    with :ok <- prompted(fields, files?) do
      case WardrikTriggers.Trigger.decode(fields, index) do
        {:ok, _trigger} -> :ok
        {:error, why} -> {:error, Error.new(:invalid_request, "A trigger doesn't read: #{why}.")}
      end
    end
  end

  @doc "Returns the servers the definition names that aren't available: not resolved, or down."
  @spec missing(Wardrik.t(), String.t(), map()) :: [String.t()]
  def missing(wardrik, id, definition) do
    servers =
      case Resolver.resolve(wardrik, id, definition) do
        {:ok, resolved} -> resolved.servers
        {:error, _error} -> %{}
      end

    mcp = Wardrik.mcp(wardrik)

    for tool <- expanded(wardrik, servers, Map.get(definition, "tools", [])),
        {:server, name} <- [named(wardrik, tool)],
        WardrikMCP.tools(nil,
          name: mcp,
          servers: Wardrik.MCPTools.picked(mcp, servers, names: [name])
        ) == [],
        do: tool
  end

  @doc "Returns how long the agent `id` idles before it sleeps, in milliseconds, or `:infinity`."
  @spec idle_timeout(Wardrik.t(), String.t(), map()) :: pos_integer() | :infinity
  def idle_timeout(wardrik, id, definition) do
    defaults =
      case Resolver.resolve(wardrik, id, definition) do
        {:ok, resolved} -> Map.merge(wardrik.defaults, resolved.defaults)
        {:error, _error} -> wardrik.defaults
      end

    seconds(
      Map.get(definition, "idle_timeout", Map.get(defaults, "idle_timeout", wardrik.idle_timeout))
    )
  end

  defp triggers(definition) do
    files? = files?(definition)

    definition
    |> Map.get("triggers", [])
    |> Enum.with_index(1)
    |> Enum.map(fn {fields, index} -> trigger(fields, index, files?) end)
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

  defp rounds(nil), do: @rounds
  defp rounds("infinity"), do: :infinity
  defp rounds(rounds) when is_integer(rounds), do: rounds

  defp capabilities(wardrik, servers, definition) do
    named =
      Enum.map(expanded(wardrik, servers, Map.get(definition, "tools", [])), &named(wardrik, &1))

    case Enum.find(named, &match?({:error, _error}, &1)) do
      nil -> {:ok, entries(wardrik, definition, named)}
      error -> error
    end
  end

  defp expanded(wardrik, servers, tools), do: Enum.flat_map(tools, &expand(wardrik, servers, &1))

  defp expand(wardrik, servers, "*"),
    do:
      Map.keys(wardrik.capabilities) ++
        Enum.map(Map.keys(servers), &"#{&1}/*") ++ ["servers/*", "workers/*", "files"]

  defp expand(_wardrik, _servers, tool), do: [tool]

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

  defp entries(wardrik, definition, named) do
    capabilities = for {:capability, entry} <- named, uniq: true, do: entry
    servers = for {:server, name} <- named, uniq: true, do: name
    all = :all_servers in named

    if servers == [] and not all,
      do: capabilities,
      else:
        capabilities ++
          [
            {Wardrik.MCPTools,
             mcp: Wardrik.mcp(wardrik),
             wardrik: wardrik.name,
             definition: definition,
             names: servers,
             all: all}
          ]
  end

  defp files?(definition) do
    tools = Map.get(definition, "tools", [])
    "files" in tools or "*" in tools
  end

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
