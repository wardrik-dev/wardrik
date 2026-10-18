defmodule WardrikDefinition do
  @moduledoc """
  An agent's definition, as it is written: the keys of an agent file's
  frontmatter, with its body as `instructions`, or the body of
  `PUT /v1/agents/{id}`. `spec/4` reads one into the `Wardrik.Agent.Spec` the
  agent runs on, so a definition reads alike from a file, from the HTTP API
  or from a host's own store, and says alike why it does not read.

      fields = %{"model" => "anthropic:claude-sonnet-5", "tools" => ["web_search"]}
      id = ~A"acme/triage"
      {:ok, spec} = WardrikDefinition.spec(fields, id, id, context, :defaults)

  `WardrikProtocol`'s `agent_definition.json` is the schema, and the keys a
  definition takes are read from it as this compiles: `keys/0`. An agent
  file takes them too, but `instructions`, which is its body, and `name`,
  `org` and `user` besides: `file_keys/0`. Where its agent's notices go is
  read beside its spec: `route/3`.

  What a definition may name, the host says in a `WardrikDefinition.Context`:
  the tools it ships, its MCP servers, channels, notify targets and
  policies, the defaults every agent takes, and the seams every agent gets.

  Where it came from, the source, says what it may say:

    * `{:file, name}` - an agent file the host's operator wrote, which may
      name modules as tools and policies
    * `{:api, grant}` - a definition a token holding `grant` sent. It names
      no modules, writes no policy that holds after a label, and shares only
      the trees the grant's scope covers. The grant's ceiling is the host's
      to hold it under, as `Wardrik.Grant.held/2` does
    * `:defaults` - one the host wrote from its defaults, which no token
      sent. It names no modules and writes no policy that holds after a
      label

  `WardrikDefinition.Record` keeps a definition in the store with its
  source.
  """

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Retry.Backoff
  alias Wardrik.Servers.Key
  alias WardrikDefinition.Context
  alias WardrikPolicy.Pattern

  @schema Path.join(WardrikProtocol.dir(), "agent_definition.json")
  @external_resource @schema

  {schema, :ok, ""} =
    :json.decode(File.read!(@schema), :ok, %{
      object_finish: fn pairs, acc -> {:lists.reverse(pairs), acc} end
    })

  @keys schema |> List.keyfind("properties", 0) |> elem(1) |> Enum.map(&elem(&1, 0))
  @file_keys ~w(name org user) ++ (@keys -- ["instructions"])
  @default_keys ~w(model tools policy timeout idle_timeout max_iterations retries compaction)
  @trigger_keys ~w(name prompt_file)
  @retries %{
    "attempts" => "is a whole number of tries after the first",
    "max_wait" => "is a whole number of seconds",
    "on_exhausted" => "is ask or fail"
  }
  @prompt "You are a helpful assistant. Answer briefly, and say what you do not know."

  @type source() :: {:file, String.t()} | {:api, Wardrik.Grant.t()} | :defaults
  @type fields() :: %{String.t() => term()}

  @doc "The keys a definition takes, in the order its schema lists them."
  @spec keys() :: [String.t()]
  def keys, do: @keys

  @doc "The keys an agent file's frontmatter takes."
  @spec file_keys() :: [String.t()]
  def file_keys, do: @file_keys

  @doc """
  The keys a host's defaults may set. `idle_timeout` and `retries` hold for
  every agent whose definition sets none; the others are what a host writes
  into a definition it makes, such as a new agent file.
  """
  @spec default_keys() :: [String.t()]
  def default_keys, do: @default_keys

  @doc "Whether `defaults` read as a host's defaults, or the key that does not and why."
  @spec check_defaults(fields()) :: :ok | {:error, String.t(), String.t()}
  def check_defaults(defaults) do
    case Map.keys(defaults) -- @default_keys do
      [] ->
        with :ok <- idle(defaults["idle_timeout"]), do: retries(defaults["retries"])

      [key | _rest] ->
        {:error, key, "is not a setting; expected one of #{Enum.join(@default_keys, ", ")}"}
    end
  end

  defp idle(nil), do: :ok
  defp idle("infinity"), do: :ok
  defp idle(seconds) when is_integer(seconds) and seconds > 0, do: :ok
  defp idle(_seconds), do: {:error, "idle_timeout", "is a whole number of seconds, or infinity"}

  defp retries(fields) do
    with %Backoff{} <- backoff(fields || %{}), do: :ok
  end

  @doc """
  An agent file with `fields` as its frontmatter, in the order given, and
  `prompt` after it, a short one unless given. A list or a map is written in
  YAML's flow style, as `[a, b]` and `{key: value}`, and a value is written
  as JSON, which YAML reads, where it is not a word YAML reads as itself.
  """
  @spec text([{String.t(), term()}], String.t()) :: String.t()
  def text(fields, prompt \\ @prompt) do
    front = for {key, value} <- fields, do: [key, ": ", yaml(value), "\n"]
    IO.iodata_to_binary(["---\n", front, "---\n", String.trim_trailing(prompt), "\n"])
  end

  defp yaml(value) when is_binary(value), do: word(value, ~r/\A[A-Za-z][\w.:\/@+*-]*\z/)
  defp yaml(value), do: flow(value)

  # Within [] or {} a colon can end a key, so a word there holds none.
  defp flow(list) when is_list(list), do: ["[", Enum.map_intersperse(list, ", ", &flow/1), "]"]

  defp flow(map) when is_map(map),
    do: [
      "{",
      Enum.map_intersperse(map, ", ", fn {key, value} -> [flow(key), ": ", flow(value)] end),
      "}"
    ]

  defp flow(value) when is_binary(value), do: word(value, ~r/\A[A-Za-z][\w.\/@+*-]*\z/)
  defp flow(value), do: JSON.encode!(value)

  defp word(value, word) do
    if Regex.match?(word, value) and
         String.downcase(value) not in ~w(true false null yes no on off),
       do: value,
       else: JSON.encode!(value)
  end

  @doc """
  The agent an agent file's `text` declares, and the definition it writes:
  its frontmatter, with its body as `instructions`. Its `name`, `org` and
  `user` give the agent's ID, `name` the file's own name where it has none
  and `org` the context's, which must be one of its `orgs`. What its
  settings say is checked as `spec/4` reads them.
  """
  @spec parse(String.t(), String.t(), Context.t()) ::
          {:ok, AgentID.t(), fields()} | {:error, String.t()}
  def parse(text, name, %Context{} = context) do
    with {:ok, front, body} <- split(text),
         {:ok, fields} <- frontmatter(front) do
      written(fields, String.trim(body), name, context)
    end
  catch
    {:invalid, message} -> {:error, message}
  end

  @doc """
  Whether `fields`, sent to the HTTP API, read as a definition of the agent
  `id`: keys it takes, an org of the context's `orgs`, and nothing only an
  operator may write. What its settings say is checked as `spec/4` reads
  them.
  """
  @spec accept(AgentID.t(), fields(), Context.t()) :: :ok | {:error, String.t()}
  def accept(%AgentID{} = id, fields, %Context{} = context) when is_map(fields) do
    if id.external_id,
      do: invalid!("#{id} is a conversation of #{owner(id)}; define #{owner(id)}")

    known!(fields, @keys)
    declared!(id.org, context)
    held_after!(fields["policy"], context)
    optional_string!(fields["instructions"], "instructions")
    :ok
  catch
    {:invalid, message} -> {:error, message}
  end

  @doc """
  The spec the definition `fields` of the agent `owner` writes for the agent
  `id`, written by `source`.

  `id` is `owner`, or one of its conversations: an ID with an external ID,
  whose spec has the tools of the definition's agent, its workspace tree
  among them. Its triggers and where its notices go are checked with the
  rest of it, and kept beside the spec rather than in it; see `triggers/1`
  and `route/3`.
  """
  @spec spec(fields(), AgentID.t(), AgentID.t(), Context.t(), source()) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def spec(fields, %AgentID{} = owner, %AgentID{} = id, %Context{} = context, source) do
    if owner(id) != owner, do: invalid!("#{id} is neither #{owner} nor a conversation of it")

    file? = match?({:file, _name}, source)
    system = optional_string!(fields["instructions"], "instructions") || ""
    _triggers = triggers(fields["triggers"], files?(fields), context.triggers)
    _channels = channels!(fields["channels"], owner.org, context)
    _route = route!(fields["notify"], owner.org, context)
    spec = build(fields, system, context, file?, owner)
    within!(spec, owner, context, source)

    {:ok, %{spec | id: id}}
  rescue
    error in [ArgumentError] -> {:error, Exception.message(error)}
  catch
    {:invalid, message} -> {:error, message}
  end

  @doc """
  The definition as the HTTP API writes one, as `agent_definition.json`
  describes it: what an agent file says besides its `name`, `org` and
  `user`, with one trigger as a list of one.
  """
  @spec fields(fields()) :: fields()
  def fields(fields) do
    case Map.take(fields, @keys) do
      %{"triggers" => %{} = one} = taken -> %{taken | "triggers" => [one]}
      taken -> taken
    end
  end

  @doc """
  Where the notices of the agent `owner`, whose definition is `fields`, go:
  a `WardrikNotify.Route` to the targets the host names, or `:none` where
  it says nothing of them. A target tells the agents of the orgs the host
  keeps it for, so a definition naming one kept for another org does not
  read. It is checked with the rest of the definition as `spec/5` reads it.
  """
  @spec route(fields(), AgentID.t(), Context.t()) ::
          {:ok, WardrikNotify.Route.t()} | :none | {:error, String.t()}
  def route(fields, %AgentID{org: org}, %Context{} = context) do
    route!(fields["notify"], org, context)
  catch
    {:invalid, message} -> {:error, message}
  end

  @doc """
  The tools the definition `fields` of the agent `owner` names that offer
  nothing yet, read under `context`: each `server/*` naming a server the
  owner has not added, and the host does not configure. Each offers its
  tools once the owner adds it, without the definition being put again.
  """
  @spec missing(fields(), AgentID.t(), Context.t()) :: [String.t()]
  def missing(fields, %AgentID{} = owner, %Context{} = context) do
    case Wardrik.Servers.list(context.added, Prefix.owner(owner)) do
      :unsupported ->
        []

      listed ->
        for name <- List.wrap(fields["tools"]),
            [server, "*"] <- [String.split(name, "/", parts: 2)],
            source(name, context) == :none,
            not Map.has_key?(configured(context), server),
            not added?(listed, server),
            do: name
    end
  end

  @doc "The channels a definition offers its agent in, by name."
  @spec channels(fields()) :: [String.t()]
  def channels(fields), do: Map.get(fields, "channels") || []

  @doc """
  The triggers a definition lists, which ask its agent something when they come round, read
  under `context`. They are checked with the rest of the definition as `spec/5` reads it.
  """
  @spec triggers(fields(), Context.t()) :: [WardrikTrigger.trigger()]
  def triggers(fields, %Context{} = context),
    do: triggers(fields["triggers"], files?(fields), context.triggers)

  @doc """
  `fields` with the trigger `name` set to the `:trigger` `opts` name, as the
  body of `PUT /v1/agents/{id}/triggers/{name}` writes one, read under
  `:context`: whether it was added or changed, and the trigger it reads
  into, or why it does not read.
  """
  @spec put_trigger(fields(), String.t(), trigger: map(), context: Context.t()) ::
          {:ok, fields(), :created | :changed, WardrikTrigger.trigger()} | {:error, String.t()}
  def put_trigger(fields, name, opts) do
    %{} = given = Keyword.fetch!(opts, :trigger)
    %Context{} = context = Keyword.fetch!(opts, :context)
    listed = named(fields["triggers"])
    trigger = Map.put(given, "name", name)

    {status, listed} =
      if Enum.any?(listed, &(&1["name"] == name)),
        do: {:changed, Enum.map(listed, &if(&1["name"] == name, do: trigger, else: &1))},
        else: {:created, listed ++ [trigger]}

    read = triggers(listed, files?(fields), context.triggers)
    {:ok, Map.put(fields, "triggers", listed), status, Enum.find(read, &(&1.name == name))}
  catch
    {:invalid, message} -> {:error, message}
  end

  @doc "`fields` without the trigger `name`, or `{:error, :not_found}` where it has none."
  @spec delete_trigger(fields(), String.t()) :: {:ok, fields()} | {:error, :not_found}
  def delete_trigger(fields, name) do
    case Enum.split_with(named(fields["triggers"]), &(&1["name"] == name)) do
      {[], _kept} -> {:error, :not_found}
      {_gone, []} -> {:ok, Map.delete(fields, "triggers")}
      {_gone, kept} -> {:ok, Map.put(fields, "triggers", kept)}
    end
  end

  defp owner(id), do: AgentID.put_external_id(id, nil)

  # A definition a token sent shares only the trees the token's scope covers,
  # or that the deployment shares with the agent.
  defp within!(%Spec{config: config}, owner, context, {:api, %Wardrik.Grant{scope: scope}}) do
    for {WardrikWorkspace, workspace} <- config.tools,
        do: ok!(WardrikWorkspace.Spec.within(workspace, scope, id: owner, shares: context.shares))
  end

  defp within!(_spec, _owner, _context, _source), do: :ok

  defp declared!(_org, %Context{orgs: :any}), do: :ok

  defp declared!(org, %Context{orgs: orgs} = context) do
    unless org in orgs,
      do:
        invalid!(
          "#{org} is not an org #{context.names.config} declares: #{Enum.join(orgs, ", ")}"
        )
  end

  defp ok!(:ok), do: :ok
  defp ok!({:error, message}), do: invalid!("workspace " <> message)

  # A rule that holds after a label loosens what a token's ceiling holds, so
  # only a policy the operator writes may say one.
  defp held_after!(%{"allow_after" => _rules}, context),
    do:
      invalid!(
        "policy cannot allow_after in a definition; name a policy in #{context.names.policies} that does"
      )

  defp held_after!(_policy, _context), do: :ok

  defp split("---\n" <> rest) do
    case String.split(rest, ~r/^---[ \t]*$\n?/m, parts: 2) do
      [front, body] -> {:ok, front, body}
      [_unclosed] -> {:error, "has frontmatter that is never closed with ---"}
    end
  end

  defp split(text), do: {:ok, "", text}

  defp frontmatter(front) do
    case YamlElixir.read_from_string(front) do
      {:ok, fields} when is_map(fields) -> {:ok, fields}
      {:ok, nil} -> {:ok, %{}}
      {:ok, _other} -> {:error, "has frontmatter that is not a set of keys"}
      {:error, error} -> {:error, "has frontmatter that is not YAML: #{Exception.message(error)}"}
    end
  end

  defp written(fields, body, name, context) do
    known!(fields, @file_keys)

    id =
      AgentID.new!(
        optional_string!(fields["name"], "name") || name,
        org: optional_string!(fields["org"], "org") || context.org,
        user: optional_string!(fields["user"], "user")
      )

    declared!(id.org, context)
    fields = Map.drop(fields, ~w(name org user))
    fields = if body == "", do: fields, else: Map.put(fields, "instructions", body)

    {:ok, id, fields}
  rescue
    error in [ArgumentError] -> {:error, Exception.message(error)}
  end

  defp known!(fields, keys) do
    case Map.keys(fields) -- keys do
      [] -> :ok
      [key | _] -> invalid!("#{key} is not a setting; expected one of #{Enum.join(keys, ", ")}")
    end
  end

  # Everything a file and a definition say alike, for the agent `id`. `modules?`
  # lets `tools` and `policy` name modules.
  defp build(fields, system, context, modules?, id) do
    config =
      ([
         system: if(system == "", do: nil, else: system),
         tools: tools(fields, context, modules?, id)
       ] ++ context.config)
      |> put(:model_spec, fields["model"], &string!(&1, "model"))
      |> put(:max_iterations, fields["max_iterations"], &iterations!/1)
      |> compaction(fields)
      |> Config.new()

    ([
       id: id,
       description: optional_string!(fields["description"], "description"),
       config: config,
       hooks: ceilings(context, id.org) ++ policy(fields["policy"], context, modules?),
       timeout: fields["timeout"] && seconds!(fields["timeout"]),
       retry: retry!(fields["retries"] || context.defaults["retries"] || %{})
     ] ++ context.seams)
    |> put(:idle_timeout, fields["idle_timeout"] || context.defaults["idle_timeout"], &idle!/1)
    |> Spec.new()
  end

  defp put(opts, _key, nil, _cast), do: opts
  defp put(opts, key, value, cast), do: Keyword.put(opts, key, cast.(value))

  # -- tools and servers -----------------------------------------------------

  defp tools(%{"tools" => names} = fields, context, modules?, key) when is_list(names) do
    if not files?(fields), do: unreached!(fields)

    names
    |> Enum.flat_map(fn
      "files" -> [files!(fields, key, context)]
      "*" -> tool!("*", context, modules?, key) ++ [files!(fields, key, context)]
      name -> tool!(name, context, modules?, key)
    end)
    |> Enum.uniq()
  end

  defp tools(%{"tools" => _names}, _context, _modules?, _key), do: invalid!("tools is a list")

  defp tools(fields, _context, _modules?, _key) do
    unreached!(fields)
    []
  end

  defp files?(%{"tools" => names}) when is_list(names),
    do: Enum.any?(names, &(&1 in ["files", "*"]))

  defp files?(_fields), do: false

  # A workspace, or files to read into each turn, with no files tools to
  # reach them.
  defp unreached!(%{"workspace" => _workspace}),
    do: invalid!("workspace shares trees, and tools names no files to reach them with")

  defp unreached!(%{"context" => _context}),
    do:
      invalid!(
        "context names files to read into each turn, and tools names no files to read them with"
      )

  defp unreached!(_fields), do: :ok

  # The file tools over the agent's own tree, and the trees `workspace` shares.
  defp files!(fields, key, context) do
    workspace = Map.get(fields, "workspace") || %{}
    if not is_map(workspace), do: invalid!("workspace is a set of settings: shared")

    case Map.keys(workspace) -- ["shared"] do
      [] -> :ok
      [key | _rest] -> invalid!("workspace.#{key} is not a setting; expected shared")
    end

    {files, bytes} = context!(Map.get(fields, "context", []))

    with {:ok, spec} <- workspace!(key, workspace, context),
         {:ok, spec} <- WardrikWorkspace.Spec.context(spec, files),
         {:ok, spec} <- budget(spec, bytes) do
      {WardrikWorkspace, spec}
    else
      {:error, message} -> invalid!(message)
    end
  end

  # `context` is the files, or the files with how much of them each turn may
  # read.
  defp context!(%{} = context) do
    case Map.keys(context) -- ["files", "max_bytes"] do
      [] -> {Map.get(context, "files", []), Map.get(context, "max_bytes")}
      [key | _rest] -> invalid!("context.#{key} is not a setting; expected files or max_bytes")
    end
  end

  defp context!(files), do: {files, nil}

  defp budget(spec, nil), do: {:ok, spec}
  defp budget(spec, bytes), do: WardrikWorkspace.Spec.context_bytes(spec, bytes)

  defp workspace!(key, workspace, context) do
    case WardrikWorkspace.Spec.new(key, Map.get(workspace, "shared") || %{},
           shares: context.shares
         ) do
      {:ok, spec} -> {:ok, spec}
      {:error, message} -> {:error, "workspace " <> message}
    end
  end

  defp tool!("*", context, _modules?, key) do
    servers =
      for {ref, opts} <- context.servers,
          context.mcp,
          reach(key, ref, opts, context) == :ok,
          do: {context.mcp, Key.deployment(Atom.to_string(ref))}

    context.tools ++ servers ++ for({_name, source} <- context.sources, do: {source, key})
  end

  defp tool!(name, context, modules?, key) when is_binary(name) do
    case source(name, context) do
      {:all, source} -> [{source, key}]
      {:one, prefix, tool} -> invalid!(one_of(name, prefix, tool))
      :none -> named!(name, context, modules?, key)
    end
  end

  defp tool!(name, _context, _modules?, _key),
    do: invalid!("tools names #{inspect(name)}, which is not a tool")

  # A source the host names, as `name/*`: every tool it has for the agent.
  defp source(name, context) do
    with [prefix, tool] <- String.split(name, "/", parts: 2),
         {:ok, source} <- Keyword.fetch(context.sources, source_name(prefix, context)) do
      if tool == "*", do: {:all, source}, else: {:one, prefix, tool}
    else
      _not_a_source -> :none
    end
  end

  defp source_name(prefix, context),
    do: Enum.find(Keyword.keys(context.sources), &(Atom.to_string(&1) == prefix))

  defp one_of(name, prefix, tool),
    do:
      "tools names #{name}; name the source's tools as #{prefix}/*, and let a policy deny " <>
        "what is not #{tool}"

  defp named!(name, context, modules?, key) do
    pattern = Pattern.parse!(name)

    cond do
      Pattern.argument?(pattern) ->
        invalid!(
          "tools names #{name}; name the tool alone, and let a policy name what its calls act on"
        )

      server = Pattern.server(pattern) ->
        [server!(server, context, key)]

      String.contains?(name, "/") ->
        [server, tool] = String.split(name, "/", parts: 2)

        invalid!(
          "tools names #{name}; name the whole server as #{server}/*, and list #{tool} " <>
            "in its only in #{context.names.config}"
        )

      true ->
        [shipped!(name, context, modules?)]
    end
  end

  defp shipped!(name, context, modules?) do
    shipped = "a tool #{context.names.host} ships"

    case Map.fetch(Map.new(context.tools, &{&1.tool().name, &1}), name) do
      {:ok, module} -> module
      :error when modules? -> module!(name, :tool, 0, "a tool", shipped)
      :error -> invalid!("tools names #{name}, which is not #{shipped}")
    end
  end

  # A server the agent's owner added comes first, then one the host
  # configures; one neither has is the owner's to add, where the host lets
  # owners add servers.
  defp server!(name, context, key) do
    owner = Prefix.owner(key)
    added = Wardrik.Servers.list(context.added, owner)

    cond do
      context.mcp == nil -> invalid!(unconfigured(name, context))
      added?(added, name) -> {context.mcp, Key.new(owner, name)}
      ref = configured(context)[name] -> configured!(name, ref, context, key)
      added != :unsupported -> {context.mcp, Key.new(owner, name)}
      true -> invalid!(unconfigured(name, context))
    end
  end

  defp configured!(name, ref, context, key) do
    case reach(key, ref, Keyword.fetch!(context.servers, ref), context) do
      :ok -> {context.mcp, Key.deployment(name)}
      {:error, why} -> invalid!("tools names #{name}/*, but #{why}")
    end
  end

  defp configured(context), do: Map.new(Keyword.keys(context.servers), &{Atom.to_string(&1), &1})

  defp added?(:unsupported, _name), do: false
  defp added?(listed, name), do: Enum.any?(listed, &(&1.name == name))

  defp unconfigured(name, context),
    do:
      "tools names #{name}/*, but #{context.names.config} configures no server #{name}" <>
        configured_servers(configured(context))

  # Whether the agent `id` can reach the server `ref`: one serving a prefix
  # that covers it.
  defp reach(%AgentID{} = id, ref, opts, context) do
    serves = Keyword.get(opts, :serves, [Prefix.all()])

    if Enum.any?(serves, &Prefix.covers?(&1, id)),
      do: :ok,
      else: {:error, not_served(ref, serves, id, context)}
  end

  defp not_served(ref, serves, id, context),
    do: "#{context.names.config}'s #{ref} serves #{Enum.join(serves, ", ")}, and not #{id}"

  defp configured_servers(configured) when map_size(configured) == 0, do: ""

  defp configured_servers(configured),
    do:
      ["; it has ", Enum.map_join(configured, ", ", fn {name, _ref} -> name end)]
      |> IO.iodata_to_binary()

  # -- triggers -------------------------------------------------------------

  defp triggers(nil, _files?, _offered), do: []
  defp triggers(%{} = one, files?, offered), do: triggers([one], files?, offered)

  defp triggers(list, files?, offered) when is_list(list) do
    triggers = list |> Enum.with_index(1) |> Enum.map(&trigger!(&1, files?, offered))

    case triggers -- Enum.uniq_by(triggers, & &1.name) do
      [] -> triggers
      [twice | _] -> invalid!("trigger names #{twice.name} twice")
    end
  end

  defp triggers(_other, _files?, _offered),
    do: invalid!("triggers is a trigger, or a list of them")

  # The triggers a checked definition lists, each with the name it is known by.
  defp named(nil), do: []
  defp named(%{} = one), do: named([one])

  defp named(list) do
    for {fields, index} <- Enum.with_index(list, 1),
        do: Map.put_new(fields, "name", "trigger-#{index}")
  end

  defp trigger!({%{} = fields, index}, files?, offered) do
    keys = @trigger_keys ++ WardrikTrigger.keys(offered)

    case Map.keys(fields) -- keys do
      [] ->
        :ok

      [key | _] ->
        invalid!("trigger #{key} is not a setting; expected one of #{Enum.join(keys, ", ")}")
    end

    name = optional_string!(fields["name"], "trigger name") || "trigger-#{index}"

    with {:ok, fields} <- prompted(fields, name, files?),
         {:ok, trigger} <-
           WardrikTrigger.decode(name, Map.delete(fields, "name"), offered: offered) do
      trigger
    else
      {:error, message} -> invalid!("trigger #{fields["name"] || index}: #{message}")
    end
  end

  defp trigger!({_other, index}, _files?, _offered),
    do: invalid!("trigger #{index} is not a set of keys")

  # A trigger's prompt_file is a prompt asking the agent to follow the file,
  # which it reads with read_file as the turn runs, so it reads it as it
  # stands then, and its labels with it.
  defp prompted(%{"prompt_file" => _file, "prompt" => _prompt}, _name, _files?),
    do: {:error, "a trigger has a prompt or a prompt_file, not both"}

  defp prompted(%{"prompt_file" => _file}, _name, false),
    do: {:error, "prompt_file names a file, and tools names no files to read it with"}

  defp prompted(%{"prompt_file" => file} = fields, name, true) do
    case WardrikWorkspace.Path.normalize(file) do
      {:ok, path} ->
        {:ok,
         fields
         |> Map.delete("prompt_file")
         |> Map.put(
           "prompt",
           "It is time for #{name}. Read #{path} with read_file, and do what it says as it stands now. If it asks nothing of you, answer in one line."
         )}

      {:error, message} ->
        {:error, "prompt_file: " <> message}
    end
  end

  defp prompted(fields, _name, _files?), do: {:ok, fields}

  # -- notify ----------------------------------------------------------------

  defp route!(nil, _org, _context), do: :none

  defp route!(target, org, context) when is_binary(target),
    do: route!(%{"to" => [target]}, org, context)

  defp route!(targets, org, context) when is_list(targets),
    do: route!(%{"to" => targets}, org, context)

  defp route!(%{} = fields, org, context) do
    case Map.keys(fields) -- ~w(to on) do
      [] -> :ok
      [key | _] -> invalid!("notify #{key} is not a setting; expected to or on")
    end

    targets = fields |> Map.get("to") |> List.wrap()
    if targets == [], do: invalid!("notify names no target")

    {:ok,
     %WardrikNotify.Route{
       targets: Enum.map(targets, &target!(&1, org, context)),
       on: fields |> Map.get("on", ~w(parked failed)) |> List.wrap() |> Enum.map(&kind!/1)
     }}
  end

  defp route!(_other, _org, _context),
    do: invalid!("notify is a target, a list of them, or to and on")

  defp target!(name, org, context) when is_binary(name) do
    names = Keyword.keys(context.targets)
    config = context.names.config

    case Enum.find(names, &(Atom.to_string(&1) == name)) do
      nil ->
        invalid!(
          IO.iodata_to_binary([
            "notify names #{name}, but #{config}'s notify has no target #{name}",
            known_targets(names)
          ])
        )

      target ->
        if not WardrikNotify.tells?(context.targets, target, org),
          do: invalid!("notify names #{name}, which #{config}'s notify keeps for another org")

        target
    end
  end

  defp target!(name, _org, _context),
    do: invalid!("notify names #{inspect(name)}, which is not a target")

  defp known_targets([]), do: []

  defp known_targets(names),
    do: ["; it has " | Enum.map_intersperse(names, ", ", &Atom.to_string/1)]

  defp kind!(kind) do
    case Enum.find(WardrikNotify.Route.kinds(), &(Atom.to_string(&1) == kind)) do
      nil -> invalid!("notify on lists #{inspect(kind)}; expected parked, failed or finished")
      found -> found
    end
  end

  # -- channels ----------------------------------------------------------------

  defp channels!(nil, _org, _context), do: []

  defp channels!(names, org, context) when is_list(names),
    do: for(name <- names, do: channel!(name, org, context))

  defp channels!(_other, _org, _context),
    do: invalid!("channels is a list of the channels it is offered in")

  defp channel!(name, org, context) do
    config = context.names.config

    case Enum.find(context.channels, fn {channel, _orgs} -> Atom.to_string(channel) == name end) do
      nil ->
        invalid!("channels names #{inspect(name)}, but #{config}'s channels has no such channel")

      {_channel, :all} ->
        name

      {_channel, served} ->
        if org in served,
          do: name,
          else: invalid!("channels names #{name}, which #{config} keeps for another org")
    end
  end

  # -- scalars ---------------------------------------------------------------

  # The policies the host holds every agent of `org` to, ahead of its own,
  # each named for where the host sets it, so its budget meters apart, and
  # every agent of the org spends from it together.
  defp ceilings(context, org) do
    for owner <- ["*", org], name = context.ceilings[owner], name != nil do
      case Map.fetch(context.policies, name) do
        {:ok, policy} ->
          WardrikPolicy.ceiling(%{policy | name: "orgs/#{owner}/#{name}"}, org)

        :error ->
          invalid!(
            "#{context.names.config} holds #{org}'s agents to the ceiling #{name}, " <>
              "which is not a policy in #{context.names.policies}"
          )
      end
    end
    |> List.flatten()
  end

  defp policy(nil, _context, _modules?), do: []

  defp policy(name, context, modules?) when is_binary(name) do
    known = "a policy in #{context.names.policies}"

    case Map.fetch(context.policies, name) do
      {:ok, policy} ->
        WardrikPolicy.hooks(policy)

      :error when modules? ->
        module = module!(name, :call, 2, "a hook", known)
        [Wardrik.Hook.new(name, module)]

      :error ->
        invalid!("policy names #{name}, which is not #{known}")
    end
  end

  defp policy(fields, _context, _modules?) when is_map(fields) do
    case WardrikPolicy.decode(fields) do
      {:ok, policy} -> WardrikPolicy.hooks(policy)
      {:error, message} -> invalid!("policy " <> message)
    end
  end

  defp policy(_value, _context, _modules?),
    do: invalid!("policy is the name of a policy, rules, or a module")

  defp module!(name, function, arity, what, known) do
    module = Module.safe_concat([name])

    if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
      do: module,
      else: invalid!("#{name} is not #{what}")
  rescue
    ArgumentError -> invalid!("names #{name}, which is neither #{known} nor a module")
  end

  defp compaction(config, %{"compaction" => false}), do: Keyword.put(config, :history, nil)

  defp compaction(config, %{"compaction" => %{} = fields}) do
    case Map.keys(fields) -- ~w(at keep window) do
      [] ->
        compaction =
          Wardrik.Compaction.new(
            at: share!(fields, "at", 0.6),
            keep: share!(fields, "keep", 0.25),
            window: window!(fields["window"])
          )

        Keyword.put(config, :history, {Wardrik.Compaction, compaction})

      [key | _] ->
        invalid!("compaction #{key} is not a setting; expected at, keep or window")
    end
  end

  defp compaction(_config, %{"compaction" => _other}),
    do: invalid!("compaction is false, or a set of at, keep and window")

  defp compaction(config, _fields), do: config

  defp share!(fields, key, default) do
    case Map.get(fields, key, default) do
      n when is_number(n) and n > 0 and n < 1 -> n / 1
      _other -> invalid!("compaction #{key} is a share of the window, between 0 and 1")
    end
  end

  defp window!(nil), do: nil
  defp window!(n) when is_integer(n) and n > 0, do: n
  defp window!(_n), do: invalid!("compaction window is a whole number of tokens")

  defp seconds!(seconds) when is_integer(seconds) and seconds > 0, do: :timer.seconds(seconds)
  defp seconds!(_seconds), do: invalid!("timeout is a whole number of seconds")

  defp idle!(seconds) when is_integer(seconds) and seconds > 0, do: :timer.seconds(seconds)
  defp idle!("infinity"), do: :infinity
  defp idle!(_seconds), do: invalid!("idle_timeout is a whole number of seconds, or infinity")

  defp iterations!(n) when is_integer(n) and n > 0, do: n
  defp iterations!("infinity"), do: :infinity
  defp iterations!(_n), do: invalid!("max_iterations is a whole number, or infinity")

  defp retry!(fields) do
    case backoff(fields) do
      %Backoff{} = backoff -> backoff
      {:error, key, message} -> invalid!("#{key} #{message}")
    end
  end

  # `retries`, with the defaults of a `Wardrik.LLM.Retry.Backoff` for what it
  # leaves out.
  defp backoff(%{} = fields) do
    Enum.reduce_while(fields, %Backoff{}, fn {key, value}, backoff ->
      case retry(key, value) do
        {:ok, field, value} -> {:cont, Map.replace!(backoff, field, value)}
        {:error, message} -> {:halt, {:error, "retries.#{key}", message}}
      end
    end)
  end

  defp backoff(_fields),
    do: {:error, "retries", "is a set of attempts, max_wait and on_exhausted"}

  defp retry("attempts", n) when is_integer(n) and n >= 0, do: {:ok, :attempts, n}
  defp retry("max_wait", s) when is_integer(s) and s >= 0, do: {:ok, :max_wait, :timer.seconds(s)}
  defp retry("on_exhausted", "ask"), do: {:ok, :on_exhausted, :ask}
  defp retry("on_exhausted", "fail"), do: {:ok, :on_exhausted, :fail}
  defp retry(key, _value) when is_map_key(@retries, key), do: {:error, @retries[key]}

  defp retry(_key, _value),
    do: {:error, "is not a setting; expected attempts, max_wait or on_exhausted"}

  defp string!(value, _key) when is_binary(value), do: value
  defp string!(_value, key), do: invalid!("#{key} is a string")

  defp optional_string!(nil, _key), do: nil

  defp optional_string!(value, _key) when is_binary(value) or is_integer(value),
    do: to_string(value)

  defp optional_string!(_value, key), do: invalid!("#{key} is a string")

  defp invalid!(message), do: throw({:invalid, message})
end
