defmodule Wardrik.Resolution do
  @moduledoc false

  alias Wardrik.Error
  alias Wardrik.Operations.Running
  alias Wardrik.Resolved
  alias Wardrik.Resolver
  alias Wardrik.Resolver.Request
  alias Wardrik.Setup

  @rounds 25

  @doc "Returns the agent `id`'s start options, from its definition and what it resolves to."
  @spec resolve(Wardrik.t(), String.t(), map()) :: {:ok, keyword()} | {:error, Error.t()}
  def resolve(wardrik, id, definition) do
    with {:ok, resolved} <- Resolver.resolve(wardrik, %Request{agent: id, definition: definition}),
         :ok <- used(wardrik, resolved),
         {:ok, opts} <- resolved(within(wardrik, resolved), id, definition, resolved),
         do: {:ok, hold(opts, resolved)}
  end

  # Each server and notify target another owner keeps is used only as the authorizer allows. An
  # agent that acts for no one is given what the resolver gives it.
  defp used(_wardrik, %Resolved{principal: nil}), do: :ok

  defp used(_wardrik, %Resolved{servers: servers, notify: notify})
       when map_size(servers) == 0 and map_size(notify) == 0,
       do: :ok

  defp used(wardrik, %Resolved{principal: principal, servers: servers, notify: notify}) do
    servers =
      for {name, key} <- servers,
          do:
            {Wardrik.Operations.Servers.owner(wardrik, key), {"mcp_server.use", :mcp_server},
             "server #{name}"}

    targets =
      for {name, target} <- notify,
          do:
            {Wardrik.Operations.NotifyTargets.owner(target),
             {"notify_target.use", :notify_target}, "notify target #{name}"}

    refused =
      for {owner, use, what} <- servers ++ targets,
          owner not in [nil, principal.id],
          not Wardrik.Owned.usable?(wardrik, principal, %{owner: owner}, use),
          do: "#{principal.id} may not use #{owner}'s #{what}."

    case refused do
      [] -> :ok
      refused -> {:error, Error.new(:invalid_request, Enum.join(refused, " "))}
    end
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

  # Every check runs, so a definition's problems come back together.
  defp resolved(wardrik, id, definition, resolved) do
    definition = Map.merge(wardrik.defaults, definition)
    servers = resolved.servers

    checked = [
      triggers: triggers(definition),
      model: model(definition),
      capabilities: capabilities(wardrik, servers, definition),
      workspace:
        Wardrik.Workspace.Agents.resolve(wardrik,
          agent: id,
          definition: definition,
          workspaces: resolved.workspaces,
          files: files?(definition)
        ),
      channels: channels(wardrik, Map.get(definition, "channels", [])),
      notify: Wardrik.Notify.check(wardrik, resolved.notify, definition),
      policy: policy(wardrik, definition["policy"]),
      boundary: policy(wardrik, Wardrik.Definitions.boundary(wardrik, id))
    ]

    with {:ok, got} <- all(checked) do
      {:ok,
       [
         agent_id: id,
         model: got.model,
         instructions: definition["instructions"],
         capabilities: got.capabilities ++ got.workspace[:capabilities],
         middleware: got.workspace[:middleware] ++ compaction(definition["compaction"]),
         retries: retries(definition["retries"]),
         model_options: model_options(definition["model_options"]),
         principal: resolved.principal,
         policy: Enum.reject([got.boundary, gating(got.policy)], &is_nil/1),
         timeout: seconds(definition["timeout"]),
         max_rounds: rounds(definition["max_iterations"])
       ]}
    end
  end

  # An invalid request names each problem. Anything else, as a store down, comes back alone.
  defp all(checked) do
    case for({_check, {:error, error}} <- checked, do: error) do
      [] ->
        {:ok, Map.new(checked, fn {check, result} -> {check, value(result)} end)}

      errors ->
        case Enum.find(errors, &(&1.type != :invalid_request)) do
          nil -> {:error, Error.new(:invalid_request, Enum.map_join(errors, " ", & &1.message))}
          error -> {:error, error}
        end
    end
  end

  defp value(:ok), do: nil
  defp value({:ok, value}), do: value

  @doc """
  Refreshes the awake agents `ids`, or all of them. Returns a line for each failure.
  """
  @spec refresh(Wardrik.t(), [String.t()] | :all) :: [String.t()]
  def refresh(wardrik, ids) do
    agents = Wardrik.agents(wardrik)

    for {agent, _conversation} = key <- WardrikCore.list(agents),
        refreshing?(ids, agent),
        Running.whereis(wardrik, key) != nil,
        {:error, error} <- [refreshed(wardrik, key)],
        do: "#{Running.describe(key)}: #{error.message}"
  end

  defp refreshing?(:all, _agent), do: true
  defp refreshing?(ids, agent), do: agent in ids

  defp refreshed(wardrik, {agent, conversation}) do
    with {:ok, definition} <- Running.definition(wardrik, agent),
         {:ok, opts} <- resolve(wardrik, agent, definition),
         do: Running.bring(wardrik, Running.held(opts, conversation))
  end

  @doc "Returns `:ok` if the trigger in `fields` is valid for the agent `definition`."
  @spec trigger(Wardrik.t(), map(), map(), pos_integer()) :: :ok | {:error, Error.t()}
  def trigger(wardrik, definition, fields, index),
    do: trigger(fields, index, files?(Map.merge(wardrik.defaults, definition)))

  defp trigger(fields, index, files?) do
    with :ok <- prompted(fields, files?) do
      case Wardrik.Triggers.Trigger.decode(fields, index) do
        {:ok, _trigger} -> :ok
        {:error, why} -> {:error, Error.new(:invalid_request, "A trigger doesn't read: #{why}.")}
      end
    end
  end

  @doc "Returns the servers the definition names that aren't resolved or are down."
  @spec missing(Wardrik.t(), String.t(), map()) :: [String.t()]
  def missing(wardrik, id, definition) do
    servers =
      case Resolver.resolve(wardrik, %Request{agent: id, definition: definition}) do
        {:ok, resolved} -> resolved.servers
        {:error, _error} -> %{}
      end

    mcp = Wardrik.mcp(wardrik)

    for tool <- expanded(wardrik, servers, Map.get(definition, "tools", [])),
        {:server, name} <- [named(wardrik, tool)],
        Wardrik.MCP.tools(nil,
          name: mcp,
          servers: Wardrik.MCP.Capability.picked(mcp, servers, names: [name])
        ) == [],
        do: tool
  end

  @doc "Returns how long the agent `id` idles before it sleeps, in milliseconds, or `:infinity`."
  @spec idle_timeout(Wardrik.t(), String.t(), map()) :: pos_integer() | :infinity
  def idle_timeout(wardrik, id, definition),
    do: seconds(setting(wardrik, id, definition, "idle_timeout", wardrik.idle_timeout))

  @doc "Returns whether the agent `id` writes a digest of each conversation before it sleeps."
  @spec digest?(Wardrik.t(), String.t(), map()) :: boolean()
  def digest?(wardrik, id, definition) do
    defaults = defaults(wardrik, id, definition)
    definition = Map.merge(defaults, definition)
    files?(definition) and Map.get(definition, "digest", true)
  end

  defp setting(wardrik, id, definition, key, default),
    do: Map.get(definition, key, Map.get(defaults(wardrik, id, definition), key, default))

  defp defaults(wardrik, id, definition) do
    case Resolver.resolve(wardrik, %Request{agent: id, definition: definition}) do
      {:ok, resolved} -> Map.merge(wardrik.defaults, resolved.defaults)
      {:error, _error} -> wardrik.defaults
    end
  end

  defp triggers(definition) do
    files? = files?(definition)

    definition
    |> Map.get("triggers", [])
    |> Enum.with_index(1)
    |> Enum.map(fn {fields, index} -> trigger(fields, index, files?) end)
    |> joined()
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
    case Wardrik.Workspace.Path.normalize(file) do
      {:ok, _path} -> :ok
      {:error, why} -> {:error, Error.new(:invalid_request, "A trigger's prompt_file: #{why}.")}
    end
  end

  defp prompted(_fields, _files?), do: :ok

  # A model the catalog doesn't list may still be served, as a fine-tune or through a gateway, so
  # only what can never work is refused.
  defp model(%{"model" => model}) when is_binary(model) do
    case ReqLLM.model(model) do
      {:ok, _model} -> {:ok, model}
      {:error, _reason} -> {:error, Error.new(:invalid_request, unmodelled(model))}
    end
  end

  defp model(%{"model" => model}),
    do: {:error, Error.new(:invalid_request, "#{inspect(model)} isn't a model.")}

  defp model(_definition),
    do: {:error, Error.new(:invalid_request, "A definition names a model.")}

  defp unmodelled(model) do
    case String.split(model, ":", parts: 2) do
      [provider, _id] ->
        "#{model} isn't a model: there's no provider #{provider}. Models are named as provider:model, such as anthropic:claude-haiku-4-5."

      [_id] ->
        "#{model} isn't a model. Models are named as provider:model, such as anthropic:claude-haiku-4-5."
    end
  end

  defp rounds(nil), do: @rounds
  defp rounds("infinity"), do: :infinity
  defp rounds(rounds) when is_integer(rounds), do: rounds

  defp capabilities(wardrik, servers, definition) do
    named =
      wardrik
      |> expanded(servers, Map.get(definition, "tools", []))
      |> Enum.map(&named(wardrik, &1))

    with :ok <- joined(named), do: {:ok, entries(wardrik, definition, named)}
  end

  defp joined(results) do
    case for({:error, error} <- results, do: error.message) do
      [] -> :ok
      messages -> {:error, Error.new(:invalid_request, Enum.join(messages, " "))}
    end
  end

  defp expanded(wardrik, servers, tools), do: Enum.flat_map(tools, &expand(wardrik, servers, &1))

  defp expand(wardrik, servers, "*") do
    names = Map.keys(servers)

    Map.keys(wardrik.capabilities) ++
      Enum.map(names, &"#{&1}/*") ++ ["servers/*", "workers/*", "files"]
  end

  defp expand(_wardrik, _servers, tool), do: [tool]

  defp named(_wardrik, "servers/*"), do: :all_servers
  defp named(_wardrik, "files"), do: :files

  defp named(wardrik, "agents/*"),
    do: {:capability, {Wardrik.AgentTools, wardrik: wardrik.name, reach: :agents}}

  defp named(wardrik, "self/*"),
    do: {:capability, {Wardrik.AgentTools, wardrik: wardrik.name, reach: :self}}

  defp named(wardrik, "workers/*"), do: {:capability, {Wardrik.Workers, wardrik: wardrik.name}}

  defp named(wardrik, "ops/read"),
    do: {:capability, {Wardrik.OperationTools, wardrik: wardrik.name, operations: :read}}

  defp named(wardrik, "ops/" <> id) do
    if Wardrik.OperationTools.offered?(id),
      do: {:capability, {Wardrik.OperationTools, wardrik: wardrik.name, operations: id}},
      else:
        {:error, Error.new(:invalid_request, "There's no operation #{id} an agent can be given.")}
  end

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
            {Wardrik.MCP.Capability,
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

  # Only these keys: other options, such as base_url, would send the deployment's keys elsewhere.
  defp model_options(nil), do: []
  defp model_options(options), do: for({key, value} <- options, do: model_option(key, value))

  defp model_option("temperature", value), do: {:temperature, value}
  defp model_option("top_p", value), do: {:top_p, value}
  defp model_option("max_tokens", value), do: {:max_tokens, value}
  defp model_option("reasoning_effort", value), do: {:reasoning_effort, effort(value)}
  defp model_option("receive_timeout", value), do: {:receive_timeout, :timer.seconds(value)}

  defp model_option("stream_idle_timeout", value),
    do: {:stream_idle_timeout, :timer.seconds(value)}

  defp model_option("total_timeout", value), do: {:total_timeout, :timer.seconds(value)}

  @efforts ~w(none minimal low medium high xhigh max default)
  defp effort(value) when value in @efforts, do: String.to_existing_atom(value)

  defp compaction(false), do: []
  defp compaction(nil), do: [{Wardrik.Compaction, []}]

  defp compaction(settings),
    do: [{Wardrik.Compaction, for({key, value} <- settings, do: {compaction_key(key), value})}]

  defp compaction_key("at"), do: :at
  defp compaction_key("keep"), do: :keep
  defp compaction_key("window"), do: :window

  defp gating(nil), do: Wardrik.Policy.new!(default: [gated: :ask])

  defp gating(%Wardrik.Policy{by_annotation: by_annotation} = policy),
    do: %{policy | by_annotation: Map.put_new(by_annotation, "gated", :ask)}

  defp channels(wardrik, names) do
    names
    |> Enum.reject(&Map.has_key?(wardrik.channels, &1))
    |> Enum.map(&{:error, Error.new(:invalid_request, "There's no channel #{&1} here.")})
    |> joined()
  end

  defp policy(_wardrik, nil), do: {:ok, nil}

  defp policy(wardrik, name) when is_binary(name) do
    case Map.fetch(wardrik.policies, name) do
      {:ok, policy} -> {:ok, policy}
      :error -> {:error, Error.new(:invalid_request, "There's no policy #{name} here.")}
    end
  end

  defp policy(_wardrik, rules) do
    case Wardrik.Policy.decode(rules) do
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
