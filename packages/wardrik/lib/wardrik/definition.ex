defmodule Wardrik.Definition do
  @moduledoc """
  An agent's definition, read once: what an agent file's frontmatter says,
  with its body as `instructions`, the body of `PUT /v1/agents/{id}`, or a
  host's defaults, checked and read into what its agent is given.
  `Wardrik.Definitions` keeps it, and `spec/3` builds the
  `Wardrik.Agent.Spec` the agent runs on from it each time it starts.

      fields = %{"model" => "anthropic:claude-sonnet-5", "tools" => ["web_search"]}
      {:ok, definition} = Wardrik.Definition.read(fields, id: ~A"acme/triage", source: :defaults, context: context)
      {:ok, spec} = Wardrik.Definition.spec(definition, ~A"acme/triage", context: context, host: host)

  `read/2` applies what the context gives every agent where the definition
  says none, `idle_timeout` and `retries`, once, so an agent keeps them
  until its definition is read again. A policy it names is kept by its
  name, one written in place as it reads, and the tools it names by their
  names: `spec/3` finds each as the agent starts.

  `WardrikProtocol`'s `agent_definition.json` is the schema, and the keys a
  definition takes are read from it as this compiles: `keys/0`. An agent
  file takes them too, but `instructions`, which is its body, and `name`,
  `org` and `user` besides: `file_keys/0`.

  What a definition may name, the host says in its `Wardrik.Host`, the
  tools and tool sources it holds and the runtimes that read its settings,
  and in a `WardrikDefinition.Context`: its MCP servers and policies, and
  the defaults every agent takes. The channels and notify
  targets it names are read as names: a channel offers only the agents of
  the orgs it serves, and a target tells only those of the orgs it is kept
  for.

  Where it came from, the source, says what it may say:

    * `{:file, path}` - an agent file the host's operator wrote, which may
      name modules as tools and policies
    * `{:api, token}` - a definition sent with the `Wardrik.Token`
      `token`. It names no modules, writes no policy that holds after a
      label, and shares only the trees whose owners' agents the token
      reaches. The policy the token names holds it, ahead of its own
    * `:defaults` - one the host wrote from its defaults, which no token
      sent. It names no modules and writes no policy that holds after a
      label
  """

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias Wardrik.Host
  alias Wardrik.LLM.Retry.Backoff
  alias Wardrik.Resource
  alias Wardrik.Runtime
  alias WardrikDefinition.Context
  alias WardrikPolicy.Pattern

  @enforce_keys [:id, :display_name, :retry, :source]
  defstruct [
    :id,
    :display_name,
    :description,
    :instructions,
    :policy,
    :timeout,
    :idle_timeout,
    :retry,
    :notify,
    :source,
    tools: [],
    triggers: [],
    channels: [],
    held: [],
    fields: %{}
  ]

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

  @type source() :: {:file, Path.t()} | {:api, Wardrik.Token.t()} | :defaults
  @type fields() :: %{String.t() => term()}

  @typedoc """
  A definition, read: the agent's `id`, the name a person calls it by, its
  name unless given, what it is for and its instructions; the `tools` and
  `channels` it names, and its `notify` route, as names; its `policy`, by
  name or as it reads; its `timeout`, `idle_timeout` and `retry`, the
  context's where it says none; its `triggers`; where it came from, the
  hooks it is `held` to ahead of its own, and its `fields`, as written,
  from which its settings are read as it starts.
  """
  @type t() :: %__MODULE__{
          id: AgentID.t(),
          display_name: String.t(),
          description: String.t() | nil,
          instructions: String.t() | nil,
          tools: [String.t()],
          policy: String.t() | WardrikPolicy.t() | nil,
          timeout: pos_integer() | nil,
          idle_timeout: timeout() | nil,
          retry: Backoff.t(),
          triggers: [WardrikTrigger.trigger()],
          notify: WardrikNotify.Route.t() | nil,
          channels: [String.t()],
          source: source(),
          held: [Wardrik.Hook.t()],
          fields: fields()
        }

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
  settings say is checked as `read/2` and `spec/3` read them.
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
  Reads `fields` as the definition of the agent `:id`, written by
  `:source`, under `:context`, held to the `:held` hooks ahead of its own,
  none unless given: the definition, or a message saying why it does not
  read. It reads nothing but what it is given.

  Its keys must be a definition's, its org one of the context's `orgs`,
  and the policies it and the token that sent it name the context's; its
  triggers are checked as they are read. Its tools and settings are checked
  as `spec/3` reads them.
  """
  @spec read(fields(),
          id: AgentID.t(),
          source: source(),
          context: Context.t(),
          held: [Wardrik.Hook.t()]
        ) :: {:ok, t()} | {:error, String.t()}
  def read(fields, opts) when is_map(fields) do
    opts = Keyword.validate!(opts, [:id, :source, :context, held: []])
    %AgentID{} = id = Keyword.fetch!(opts, :id)
    %Context{} = context = Keyword.fetch!(opts, :context)
    source = Keyword.fetch!(opts, :source)
    file? = match?({:file, _path}, source)

    if id.external_id,
      do: invalid!("#{id} is a conversation of #{owner(id)}; define #{owner(id)}")

    known!(fields, @keys)
    declared!(id.org, context)
    if not file?, do: held_after!(fields["policy"], context)
    if not files?(fields), do: unreached!(fields)

    definition = %__MODULE__{
      id: id,
      display_name: optional_string!(fields["display_name"], "display_name") || id.name,
      description: optional_string!(fields["description"], "description"),
      instructions: optional_string!(fields["instructions"], "instructions"),
      tools: names!(fields["tools"]),
      policy: policy!(fields["policy"]),
      timeout: fields["timeout"] && seconds!(fields["timeout"]),
      idle_timeout: idle!(fields["idle_timeout"] || context.defaults["idle_timeout"]),
      retry: retry!(fields["retries"] || context.defaults["retries"] || %{}),
      triggers: triggers(fields["triggers"], files?(fields), context.triggers),
      notify: route!(fields["notify"]),
      channels: channels!(fields["channels"]),
      source: source,
      held: opts[:held],
      fields: written_fields(fields)
    }

    _hooks = hooks!(definition, context)
    {:ok, definition}
  catch
    {:invalid, message} -> {:error, message}
  end

  @doc """
  The spec `definition` writes for the agent `id`, under `:context`, or a
  message saying what in it is not there: its own, or that of one of its
  conversations, an ID with an external ID, with the tools of the
  definition's agent, its workspace tree among them.

  The tools and policies it names are found by their names as it is asked,
  the tools and tool sources among those `:host` holds, and its settings
  read with those tools, by the first of the host's runtimes whose key it
  names, `model` for `Wardrik.LLM.Runtime`, or by the first
  where it names none. Its hooks are those it is held to, then the policy
  of the token that sent it, then those the context holds its org to, then
  its own policy.
  """
  @spec spec(t(), AgentID.t(), context: Context.t(), host: Host.t()) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def spec(%__MODULE__{id: owner, fields: fields} = definition, %AgentID{} = id, opts) do
    %Context{} = context = Keyword.fetch!(opts, :context)
    %Host{} = host = Keyword.fetch!(opts, :host)
    if owner(id) != owner, do: invalid!("#{id} is neither #{owner} nor a conversation of it")

    tools = tools(fields, context, host, match?({:file, _path}, definition.source), owner)
    within!(tools, owner, context, definition.source)
    resolved = %Runtime.Context{instructions: definition.instructions, tools: tools}

    {:ok,
     [
       id: id,
       display_name: definition.display_name,
       description: definition.description,
       config: settings!(fields, resolved, Host.runtimes(host)),
       hooks: hooks!(definition, context),
       timeout: definition.timeout,
       retry: definition.retry
     ]
     |> put(:idle_timeout, definition.idle_timeout)
     |> Spec.new()}
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
  @spec written_fields(fields()) :: fields()
  def written_fields(fields) do
    case Map.take(fields, @keys) do
      %{"triggers" => %{} = one} = taken -> %{taken | "triggers" => [one]}
      taken -> taken
    end
  end

  @doc """
  The tools `definition` names that offer nothing yet, read under
  `:context` on `:host`: each `server/*` naming a server its agent's owner
  has not added, and the host does not configure. Each offers its tools
  once the owner adds it, without the definition being read again.
  """
  @spec missing(t(), context: Context.t(), host: Host.t()) :: [String.t()]
  def missing(%__MODULE__{id: owner, tools: names}, opts) do
    %Context{} = context = Keyword.fetch!(opts, :context)
    %Host{} = host = Keyword.fetch!(opts, :host)

    case Wardrik.Servers.list(Host.servers(host), Resource.owner(AgentID.resource(owner))) do
      :unsupported ->
        []

      listed ->
        for name <- names,
            [server, "*"] <- [String.split(name, "/", parts: 2)],
            source(name, host) == :none,
            not Map.has_key?(configured(context), server),
            not added?(listed, server),
            do: name
    end
  end

  @doc """
  `definition` with the trigger `name` set to `trigger`, as the body of
  `PUT /v1/agents/{id}/triggers/{name}` writes one, read again under
  `context`: whether it was added or changed, and the trigger it reads
  into, or why it does not read.
  """
  @spec put_trigger(t(), String.t(), map(), Context.t()) ::
          {:ok, t(), :created | :changed, WardrikTrigger.trigger()} | {:error, String.t()}
  def put_trigger(%__MODULE__{fields: fields} = definition, name, %{} = trigger, context) do
    listed = named(fields["triggers"])
    trigger = Map.put(trigger, "name", name)

    {status, listed} =
      if Enum.any?(listed, &(&1["name"] == name)),
        do: {:changed, Enum.map(listed, &if(&1["name"] == name, do: trigger, else: &1))},
        else: {:created, listed ++ [trigger]}

    with {:ok, definition} <-
           again(%{definition | fields: Map.put(fields, "triggers", listed)}, context),
         do: {:ok, definition, status, Enum.find(definition.triggers, &(&1.name == name))}
  end

  @doc """
  `definition` without the trigger `name`, read again under `context`: the
  trigger it was, or `{:error, :not_found}` where it has none.
  """
  @spec delete_trigger(t(), String.t(), Context.t()) ::
          {:ok, t(), WardrikTrigger.trigger()} | {:error, :not_found} | {:error, String.t()}
  def delete_trigger(%__MODULE__{fields: fields} = definition, name, context) do
    with %{} = trigger <- Enum.find(definition.triggers, {:error, :not_found}, &(&1.name == name)),
         {:ok, definition} <- again(%{definition | fields: without(fields, name)}, context),
         do: {:ok, definition, trigger}
  end

  defp without(fields, name) do
    case Enum.reject(named(fields["triggers"]), &(&1["name"] == name)) do
      [] -> Map.delete(fields, "triggers")
      kept -> Map.put(fields, "triggers", kept)
    end
  end

  @doc """
  `definition` read again from its `fields` under `context`, from where it
  came and held as it was, so it takes what the context gives every agent
  now.
  """
  @spec again(t(), Context.t()) :: {:ok, t()} | {:error, String.t()}
  def again(%__MODULE__{} = definition, %Context{} = context),
    do:
      read(definition.fields,
        id: definition.id,
        source: definition.source,
        context: context,
        held: definition.held
      )

  defp owner(id), do: AgentID.put_external_id(id, nil)

  # A definition a token sent shares only the trees the token reaches, or
  # that the deployment shares with the agent.
  defp within!(tools, owner, context, {:api, %Wardrik.Token{} = token}) do
    for {WardrikWorkspace, workspace} <- tools,
        do: ok!(WardrikWorkspace.Spec.within(workspace, token, id: owner, shares: context.shares))
  end

  defp within!(_tools, _owner, _context, _source), do: :ok

  # The policy the token that sent a definition names, found each time its
  # agent is built, as the policy a definition names is.
  defp bounded({:api, %Wardrik.Token{policy: :none}}, _context), do: []

  defp bounded({:api, %Wardrik.Token{policy: name}}, context) do
    case Map.fetch(context.policies, name) do
      {:ok, policy} ->
        WardrikPolicy.hooks(%{policy | name: "policy/" <> name})

      :error ->
        invalid!(
          "the token that defined it names the policy #{name}, which is not a policy in " <>
            context.names.policies
        )
    end
  end

  defp bounded(_source, _context), do: []

  defp hooks!(definition, context),
    do:
      definition.held ++
        bounded(definition.source, context) ++
        ceilings(context, definition.id.org) ++
        policy_hooks(definition.policy, context, match?({:file, _path}, definition.source))

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

  # A rule that holds after a label loosens what a token's policy holds, so
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

  defp settings!(fields, resolved, [first | _rest] = runtimes) do
    runtime = Enum.find(runtimes, first, &Map.has_key?(fields, Runtime.key(&1)))

    case Runtime.read(runtime, fields, resolved) do
      {:ok, settings} -> settings
      {:error, message} -> invalid!(message)
    end
  end

  defp put(opts, _key, nil), do: opts
  defp put(opts, key, value), do: Keyword.put(opts, key, value)

  # -- tools and servers -----------------------------------------------------

  defp tools(%{"tools" => names} = fields, context, host, modules?, key) when is_list(names) do
    names
    |> Enum.flat_map(fn
      "files" -> [files!(fields, key, context)]
      "*" -> tool!("*", context, host, modules?, key) ++ [files!(fields, key, context)]
      name -> tool!(name, context, host, modules?, key)
    end)
    |> Enum.uniq()
  end

  defp tools(_fields, _context, _host, _modules?, _key), do: []

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

  defp tool!("*", context, host, _modules?, key) do
    servers =
      for {ref, opts} <- context.servers,
          context.mcp,
          reach(key, ref, opts, context) == :ok,
          do: {context.mcp, Resource.new(Resource.deployment(), server: Atom.to_string(ref))}

    Map.values(Host.tools(host)) ++
      servers ++ for({_name, source} <- Host.sources(host), do: {source, key})
  end

  defp tool!(name, context, host, modules?, key) do
    case source(name, host) do
      {:all, source} -> [{source, key}]
      {:one, prefix, tool} -> invalid!(one_of(name, prefix, tool))
      :none -> named!(name, context, host, modules?, key)
    end
  end

  # A source the host holds, as `name/*`: every tool it has for the agent.
  defp source(name, host) do
    with [prefix, tool] <- String.split(name, "/", parts: 2),
         {:ok, source} <- Map.fetch(Host.sources(host), prefix) do
      if tool == "*", do: {:all, source}, else: {:one, prefix, tool}
    else
      _not_a_source -> :none
    end
  end

  defp one_of(name, prefix, tool),
    do:
      "tools names #{name}; name the source's tools as #{prefix}/*, and let a policy deny " <>
        "what is not #{tool}"

  defp named!(name, context, host, modules?, key) do
    pattern = Pattern.parse!(name)

    cond do
      Pattern.argument?(pattern) ->
        invalid!(
          "tools names #{name}; name the tool alone, and let a policy name what its calls act on"
        )

      server = Pattern.server(pattern) ->
        [server!(server, context, host, key)]

      String.contains?(name, "/") ->
        [server, tool] = String.split(name, "/", parts: 2)

        invalid!(
          "tools names #{name}; name the whole server as #{server}/*, and list #{tool} " <>
            "in its only in #{context.names.config}"
        )

      true ->
        [shipped!(name, context, host, modules?)]
    end
  end

  defp shipped!(name, context, host, modules?) do
    shipped = "a tool #{context.names.host} ships"

    case Map.fetch(Host.tools(host), name) do
      {:ok, module} -> module
      :error when modules? -> module!(name, :tool, 0, "a tool", shipped)
      :error -> invalid!("tools names #{name}, which is not #{shipped}")
    end
  end

  # A server the agent's owner added comes first, then one the host
  # configures; one neither has is the owner's to add, where the host lets
  # owners add servers.
  defp server!(name, context, host, key) do
    owner = Resource.owner(AgentID.resource(key))
    added = Wardrik.Servers.list(Host.servers(host), owner)

    cond do
      context.mcp == nil -> invalid!(unconfigured(name, context))
      added?(added, name) -> {context.mcp, Resource.new(owner, server: name)}
      ref = configured(context)[name] -> configured!(name, ref, context, key)
      added != :unsupported -> {context.mcp, Resource.new(owner, server: name)}
      true -> invalid!(unconfigured(name, context))
    end
  end

  defp configured!(name, ref, context, key) do
    case reach(key, ref, Keyword.fetch!(context.servers, ref), context) do
      :ok -> {context.mcp, Resource.new(Resource.deployment(), server: name)}
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

  # Whether the agent `id` can reach the server `ref`: one serving a pattern
  # that covers it.
  defp reach(%AgentID{} = id, ref, opts, context) do
    serves = Keyword.get(opts, :serves, [Resource.parse!("*")])

    if Enum.any?(serves, &Resource.covers?(&1, AgentID.resource(id))),
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

  defp route!(nil), do: nil
  defp route!(target) when is_binary(target), do: route!(%{"to" => [target]})
  defp route!(targets) when is_list(targets), do: route!(%{"to" => targets})

  defp route!(%{} = fields) do
    case Map.keys(fields) -- ~w(to on) do
      [] -> :ok
      [key | _] -> invalid!("notify #{key} is not a setting; expected to or on")
    end

    targets = fields |> Map.get("to") |> List.wrap()
    if targets == [], do: invalid!("notify names no target")

    %WardrikNotify.Route{
      targets: Enum.map(targets, &target!/1),
      on: fields |> Map.get("on", ~w(parked failed)) |> List.wrap() |> Enum.map(&kind!/1)
    }
  end

  defp route!(_other), do: invalid!("notify is a target, a list of them, or to and on")

  defp target!(name) when is_binary(name), do: name
  defp target!(name), do: invalid!("notify names #{inspect(name)}, which is not a target")

  defp kind!(kind) do
    case Enum.find(WardrikNotify.Route.kinds(), &(Atom.to_string(&1) == kind)) do
      nil -> invalid!("notify on lists #{inspect(kind)}; expected parked, failed or finished")
      found -> found
    end
  end

  # -- names -------------------------------------------------------------------

  defp channels!(nil), do: []

  defp channels!(names) when is_list(names) do
    if Enum.all?(names, &is_binary/1),
      do: names,
      else: invalid!("channels is a list of the channels it is offered in")
  end

  defp channels!(_other), do: invalid!("channels is a list of the channels it is offered in")

  defp names!(nil), do: []

  defp names!(names) when is_list(names) do
    case Enum.reject(names, &is_binary/1) do
      [] -> names
      [name | _rest] -> invalid!("tools names #{inspect(name)}, which is not a tool")
    end
  end

  defp names!(_names), do: invalid!("tools is a list")

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
            "#{context.names.config} holds #{org}'s agents to the policy #{name}, " <>
              "which is not a policy in #{context.names.policies}"
          )
      end
    end
    |> List.flatten()
  end

  # A policy named is kept by its name, and one written in place as it reads.
  defp policy!(nil), do: nil
  defp policy!(name) when is_binary(name), do: name

  defp policy!(fields) when is_map(fields) do
    case WardrikPolicy.decode(fields) do
      {:ok, policy} -> policy
      {:error, message} -> invalid!("policy " <> message)
    end
  end

  defp policy!(_value), do: invalid!("policy is the name of a policy, rules, or a module")

  defp policy_hooks(nil, _context, _file?), do: []
  defp policy_hooks(%WardrikPolicy{} = policy, _context, _file?), do: WardrikPolicy.hooks(policy)

  defp policy_hooks(name, context, file?) do
    known = "a policy in #{context.names.policies}"

    case Map.fetch(context.policies, name) do
      {:ok, policy} ->
        WardrikPolicy.hooks(policy)

      :error when file? ->
        module = module!(name, :call, 2, "a hook", known)
        [Wardrik.Hook.new(name, module)]

      :error ->
        invalid!("policy names #{name}, which is not #{known}")
    end
  end

  defp module!(name, function, arity, what, known) do
    module = Module.safe_concat([name])

    if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
      do: module,
      else: invalid!("#{name} is not #{what}")
  rescue
    ArgumentError -> invalid!("names #{name}, which is neither #{known} nor a module")
  end

  defp seconds!(seconds) when is_integer(seconds) and seconds > 0, do: :timer.seconds(seconds)
  defp seconds!(_seconds), do: invalid!("timeout is a whole number of seconds")

  defp idle!(nil), do: nil
  defp idle!(seconds) when is_integer(seconds) and seconds > 0, do: :timer.seconds(seconds)
  defp idle!("infinity"), do: :infinity
  defp idle!(_seconds), do: invalid!("idle_timeout is a whole number of seconds, or infinity")

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

  defp optional_string!(nil, _key), do: nil

  defp optional_string!(value, _key) when is_binary(value) or is_integer(value),
    do: to_string(value)

  defp optional_string!(_value, key), do: invalid!("#{key} is a string")

  defp invalid!(message), do: throw({:invalid, message})
end
