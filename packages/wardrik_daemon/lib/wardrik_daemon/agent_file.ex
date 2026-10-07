defmodule WardrikDaemon.AgentFile do
  @moduledoc """
  Reads an agent file, one in `agents/` under the config directory, into the
  `Wardrik.Agent.Spec` it writes.

      ---
      name: triage
      description: Watches the incident queue and says what needs an engineer.
      model: anthropic:claude-sonnet-5
      tools: [web_search, linear/*]
      org: acme
      user: jon
      timeout: 600
      ---
      You watch the incident queue. Summarise anything new, and say which
      issues need an engineer.

  The body after the frontmatter is the agent's system prompt, and a file
  with no frontmatter is all prompt.

  | Key | What it gives the agent |
  | --- | --- |
  | `name` | its name, and with `org` and `user` its ID in the fleet. The file's name without `.md` when absent |
  | `org` | the org it belongs to. `config.yaml`'s `org` when absent |
  | `user` | the user of its org it works for, if any |
  | `description` | what it is for, as `wardrik show` shows it |
  | `model` | the model, as `provider:model`. `Wardrik.LLM.Config`'s default when absent |
  | `tools` | what it may call; see below |
  | `workspace` | the trees it shares with other agents, under `shared`; see below. A definition over HTTP cannot say it |
  | `context` | the files read into each turn; see below. A definition over HTTP cannot say it |
  | `policy` | what its tool calls may do; see below |
  | `timeout` | how many seconds a turn may take |
  | `max_iterations` | how many rounds of tool calls a turn may make, or `infinity` |
  | `compaction` | when it summarises its older history, as `at`, `keep` and `window`; see `Wardrik.Compaction`. `false` never does |
  | `schedule` | when it is asked something on a clock; see below |
  | `notify` | who hears when it parks, fails or answers; see below |

  Its ID is `org/name`, or `org/@user/name` for one that works for a user:
  the file above is `acme/@jon/triage`. See `Wardrik.Fleet`.

  ## Tools

  `tools` lists what the agent may call, and an agent whose file lists none
  has none.

    * a tool the daemon ships, by name: #{Enum.map_join(["web_search", "deep_research", "run_lua"], ", ", &"`#{&1}`")}
    * `files`, the six file tools over the agent's own tree and the trees it
      shares, as `WardrikWorkspace` describes them
    * `server/*`, every tool of an MCP server as `config.yaml` names it. A
      server's `only` and `except` narrow what it offers
    * `workers/*`, every tool the connected tool workers offer the agent, as
      `WardrikHTTP.Workers` describes them. A policy narrows what it may call
    * `*`, every tool the daemon ships, the file tools, every MCP server
      the agent can reach, and every tool worker's tools
    * a module implementing `Wardrik.Tool`

  An agent reaches an MCP server that serves its org, as the server's `org`
  in `config.yaml` says. A file naming a server its agent cannot reach does
  not read, and says why.

  ## Workspace

  `files` gives the agent a tree of its own, kept in the store, and
  `workspace` shares others with it, each seen under `shared/<name>/`:

      tools: [files]
      workspace:
        shared:
          team: acme                                  # acme's tree, read and written
          runbooks: {tree: acme/runbooks, mode: read}

  A tree is reachable by the agents under the scope its name begins with, as
  `WardrikWorkspace.Spec` says, and a file naming one its agent cannot reach
  does not read.

  As each turn begins the agent is told what its workspace holds: the files
  `context` names, up to 16 KB of them in all, and the names of the others at
  the top of its tree, which it reads when it needs them. So a `MEMORY.md` it
  keeps is there to find in every turn without filling the context:

      tools: [files]
      context: [SOUL.md, shared/team/CONVENTIONS.md]

  A file longer than its share is read from its start and its end, and the
  agent is asked to make one of its own shorter. `max_bytes` reads more or
  less of them into each turn, from 1,024 to 262,144 bytes:

      context:
        files: [SOUL.md, MEMORY.md]
        max_bytes: 65536

  A file read into the turn that a turn which had read content from outside
  wrote makes it tainted from its start. See `WardrikWorkspace.Context`.

  ## Policy

  `policy` is one of

    * the name of a policy in `policies/` under the config directory:
      `policy: careful` for `policies/careful.yaml`
    * rules written in place, as a policy file writes them:

          policy:
            ask: [github/*]
            deny: [run_lua]

    * a module implementing `Wardrik.Hook`

  and without one every call the agent's tools allow may run, apart from a
  gated tool's, which waits on a person unless a rule allows it by name. Rules,
  named or written in place, are a `WardrikPolicy`, and the agent carries them
  as its `Wardrik.Hook`s: they are written to the store with it and decide its
  calls on any node. A rule may name what a call acts on, as
  `write_file(notes/*)`. A policy with a `budget` limits what the agent spends
  on model calls too, parking it when the budget runs out until a person
  approves more.

  Once a turn has read content from outside, from `web_search`,
  `deep_research`, an MCP server `config.yaml` does not mark `trusted`, or a
  tool worker, its `allow` rules stop counting for a gated tool's calls, there
  and in every turn after it, until `wardrik clear` empties the agent's
  conversation: each waits on a person, who sees what it would do. An
  `allow_after_outside` rule still counts, for a tool whose calls may follow
  what a stranger wrote; see `WardrikPolicy`. A definition over HTTP cannot
  write one in place, though it may name a policy in `policies/` that has
  one.

  ## Schedule

  `schedule` is one schedule or a list of them, each a `Wardrik.Schedule`:

      schedule:
        - name: sweep
          every: "*/30 * * * *"
          prompt: Check the incident queue.
        - name: digest
          every: "0 17 * * 1-5"
          prompt: Write up what happened today.
          overlap: queue

    * `every` - a cron expression in UTC, quoted, since YAML reads a leading
      `*` as something else; or a duration of at least a minute, as `30m`,
      `2h` or `1d`
    * `prompt` - what the agent is asked
    * `prompt_file` - in place of `prompt`, a file in its workspace: each time
      the schedule fires the agent is asked to read it and do what it says,
      so the agent can edit the checklist it follows. It needs `files` in
      `tools`
    * `name` - the schedule's name, `schedule-1`, `schedule-2` and so on by
      its place in the list when absent
    * `overlap` - `skip`, the default, leaves an agent that is running or
      waiting on a person be, and `queue` asks it anyway
    * `missed` - `run_once`, the default, fires once for runs missed while
      the daemon was down, and `skip` lets them go
    * `jitter` - up to this many seconds added to each run

  ## Notify

  `notify` routes the agent's notices to targets `config.yaml`'s `notify`
  section names, as `WardrikNotify` describes them:

      notify: ops                      # parked and failed turns, to ops
      notify: [ops, audit]
      notify: {to: [ops], on: [parked, failed, finished]}

  `on` lists what is sent: `parked`, `failed`, and `finished` for what a turn
  answered. A target tells the agents of the org its `org` in `config.yaml`
  names, and a file routing to one for another org does not read.

  The agent resolves the credentials its tools name from `WardrikVault`: its
  user's, its org's or the deployment's, and an account its user, or its
  org, connects through `WardrikOAuth` where a provider is named for one
  nobody holds. It records every tool call in `Wardrik.Ledger.Store`, so a
  turn lost part way through runs no call twice.

  ## Over HTTP

  `definition/3` reads the body of `PUT /v1/agents/{id}` into
  a spec the same way, for `WardrikHTTP` through `WardrikDaemon.Agents`:

      {"description": "Watches the incident queue.",
       "instructions": "You watch the incident queue.",
       "model": "anthropic:claude-sonnet-5",
       "tools": ["web_search", "linear/*"],
       "policy": {"ask": ["linear/*"]}}

  `priv/protocol/v1/agent_definition.json` is its schema. `instructions` is
  the system prompt, as a file's body is, and the other keys mean what they
  mean in a file. The ID gives the agent's `name`, `org` and `user`. A definition has no `schedule` or `notify`: it leaves the
  agent's schedules as they are, and the schedules routes set them. Its
  `tools` and `policy` name what the daemon ships or configures, and never a
  module.

  ## Written by wardrik

  `wardrik init` and `wardrik agent spawn` write a file here: the frontmatter
  they choose, such as `config.yaml`'s `defaults`, and a short prompt to edit
  into what the agent is for.
  """

  alias Wardrik.Agent.Spec
  alias Wardrik.LLM.Config
  alias WardrikPolicy.Pattern

  @shipped [WardrikBrave.WebSearch, WardrikResearch.Deep, WardrikLua.Run]
  @keys ~w(name description model tools workspace context org user policy timeout max_iterations compaction schedule notify)
  @definition_keys ~w(description instructions model tools policy timeout max_iterations compaction)
  @schedule_keys ~w(name every prompt prompt_file overlap missed jitter)
  @prompt "You are a helpful assistant. Answer briefly, and say what you do not know."

  @doc """
  An agent file with `fields` as its frontmatter, in the order given, and a
  short prompt after it. A value is written as JSON, which YAML reads, where
  it is not a word YAML reads as itself.
  """
  @spec text([{String.t(), term()}]) :: String.t()
  def text(fields) do
    front = for {key, value} <- fields, do: "#{key}: #{yaml(value)}\n"
    IO.iodata_to_binary(["---\n", front, "---\n", @prompt, "\n"])
  end

  defp yaml(value) when is_binary(value) do
    if Regex.match?(~r/\A[A-Za-z][\w.:\/@+-]*\z/, value) and
         String.downcase(value) not in ~w(true false null yes no on off),
       do: value,
       else: JSON.encode!(value)
  end

  defp yaml(value), do: JSON.encode!(value)

  @doc """
  Reads the spec of the agent `path` declares, with `policies` the policies in
  `policies/`, by name.
  """
  @spec read(Path.t(), %{String.t() => WardrikPolicy.t()}) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def read(path, policies \\ %{}) do
    with {:ok, spec, _route} <- load(path, policies), do: {:ok, spec}
  end

  @doc """
  `read/2`, with where the agent's notices go: a `WardrikNotify.Route`, or `nil`
  for a file with no `notify`.
  """
  @spec load(Path.t(), %{String.t() => WardrikPolicy.t()}) ::
          {:ok, Spec.t(), WardrikNotify.Route.t() | nil} | {:error, String.t()}
  def load(path, policies \\ %{}) do
    with {:ok, text} <- File.read(path),
         {:ok, front, body} <- split(text),
         {:ok, fields} <- frontmatter(front) do
      build(path, fields, String.trim(body), policies)
    else
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      {:error, message} -> {:error, "#{path}: #{message}"}
    end
  catch
    {:invalid, message} -> {:error, "#{path}: #{message}"}
  end

  @doc """
  Reads a definition sent to the HTTP API for the agent `id` into its spec,
  with `policies` as `read/2` takes them. The spec's `schedules` is `nil`, so
  `Wardrik.Fleet.put/1` leaves the agent's schedules as they are.
  """
  @spec definition(Wardrik.AgentID.t(), map(), %{String.t() => WardrikPolicy.t()}) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def definition(%Wardrik.AgentID{} = id, fields, policies \\ %{}) when is_map(fields) do
    known!(fields, @definition_keys)
    held_after_outside!(fields["policy"])
    instructions = optional_string!(fields["instructions"], "instructions") || ""

    {:ok, spec(fields, instructions, policies, false, id, nil)}
  rescue
    error in [ArgumentError] -> {:error, Exception.message(error)}
  catch
    {:invalid, message} -> {:error, message}
  end

  # A rule that holds after content from outside loosens what a token's
  # ceiling holds, so only a policy the operator writes may say one.
  defp held_after_outside!(%{"allow_after_outside" => _rules}),
    do:
      invalid!(
        "policy cannot allow_after_outside in a definition; name a policy in policies/ that does"
      )

  defp held_after_outside!(_policy), do: :ok

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

  defp build(path, fields, body, policies) do
    known!(fields, @keys)

    id =
      Wardrik.AgentID.new!(
        optional_string!(fields["name"], "name") || path |> Path.basename() |> Path.rootname(),
        org: optional_string!(fields["org"], "org") || WardrikDaemon.Config.org(),
        user: optional_string!(fields["user"], "user")
      )

    schedules = schedules(fields["schedule"], files?(fields))
    spec = spec(fields, body, policies, true, id, schedules)

    {:ok, spec, route(fields["notify"], id.org)}
  rescue
    error in [ArgumentError] -> {:error, "#{path}: #{Exception.message(error)}"}
  end

  defp known!(fields, keys) do
    case Map.keys(fields) -- keys do
      [] -> :ok
      [key | _] -> invalid!("#{key} is not a setting; expected one of #{Enum.join(keys, ", ")}")
    end
  end

  # Everything a file and a definition say alike, for the agent `id`, which
  # each names its own way. `modules?` lets `tools` and `policy` name modules.
  defp spec(fields, system, policies, modules?, id, schedules) do
    config =
      [system: if(system == "", do: nil, else: system), tools: tools(fields, modules?, id)]
      |> put(:model_spec, fields["model"], &string!(&1, "model"))
      |> put(:max_iterations, fields["max_iterations"], &iterations!/1)
      |> compaction(fields)
      |> Config.new()

    Spec.new(
      id: id,
      schedules: schedules,
      description: optional_string!(fields["description"], "description"),
      config: config,
      hooks: policy(fields["policy"], policies, modules?),
      timeout: fields["timeout"] && seconds!(fields["timeout"]),
      credentials: WardrikVault,
      ledger: Wardrik.Ledger.Store
    )
  end

  defp put(opts, _key, nil, _cast), do: opts
  defp put(opts, key, value, cast), do: Keyword.put(opts, key, cast.(value))

  # -- tools and servers -----------------------------------------------------

  defp tools(%{"tools" => names} = fields, modules?, key) when is_list(names) do
    if not files?(fields), do: unreached!(fields)

    names
    |> Enum.flat_map(fn
      "files" -> [files!(fields, key)]
      "*" -> tool!("*", modules?, key) ++ [files!(fields, key)]
      name -> tool!(name, modules?, key)
    end)
    |> Enum.uniq()
  end

  defp tools(%{"tools" => _names}, _modules?, _key), do: invalid!("tools is a list")

  defp tools(fields, _modules?, _key) do
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
  defp files!(fields, key) do
    workspace = Map.get(fields, "workspace") || %{}
    if not is_map(workspace), do: invalid!("workspace is a set of settings: shared")

    case Map.keys(workspace) -- ["shared"] do
      [] -> :ok
      [key | _rest] -> invalid!("workspace.#{key} is not a setting; expected shared")
    end

    {files, bytes} = context!(Map.get(fields, "context", []))

    with {:ok, spec} <- workspace!(key, workspace),
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

  defp workspace!(key, workspace) do
    case WardrikWorkspace.Spec.new(key, Map.get(workspace, "shared") || %{}) do
      {:ok, spec} -> {:ok, spec}
      {:error, message} -> {:error, "workspace " <> message}
    end
  end

  defp tool!("*", _modules?, key) do
    servers =
      for {ref, opts} <- WardrikMCP.Config.servers(), reach(key, ref, opts) == :ok, do: ref

    @shipped ++ Enum.map(servers, &{WardrikMCP, &1}) ++ [{WardrikHTTP.Workers, key}]
  end

  defp tool!("workers/*", _modules?, key), do: [{WardrikHTTP.Workers, key}]

  defp tool!("workers/" <> tool = name, _modules?, _key) do
    invalid!(
      "tools names #{name}; name the workers' tools as workers/*, and let a policy deny what is not #{tool}"
    )
  end

  defp tool!(name, modules?, key) when is_binary(name) do
    pattern = Pattern.parse!(name)

    cond do
      Pattern.argument?(pattern) ->
        invalid!(
          "tools names #{name}; name the tool alone, and let a policy name what its calls act on"
        )

      server = Pattern.server(pattern) ->
        [server!(server, key)]

      String.contains?(name, "/") ->
        [server, tool] = String.split(name, "/", parts: 2)

        invalid!(
          "tools names #{name}; name the whole server as #{server}/*, and list #{tool} " <>
            "in its only in config.yaml"
        )

      true ->
        [shipped!(name, modules?)]
    end
  end

  defp tool!(name, _modules?, _key),
    do: invalid!("tools names #{inspect(name)}, which is not a tool")

  defp shipped!(name, modules?) do
    case Map.fetch(Map.new(@shipped, &{&1.tool().name, &1}), name) do
      {:ok, module} -> module
      :error when modules? -> module!(name, :tool, 0, "a tool", "a tool the daemon ships")
      :error -> invalid!("tools names #{name}, which is not a tool the daemon ships")
    end
  end

  defp server!(name, key) do
    configured = Map.new(WardrikMCP.Config.refs(), &{Atom.to_string(&1), &1})

    with {:ok, ref} <- Map.fetch(configured, name),
         :ok <- reach(key, ref, Keyword.fetch!(WardrikMCP.Config.servers(), ref)) do
      {WardrikMCP, ref}
    else
      {:error, why} ->
        invalid!("tools names #{name}/*, but #{why}")

      :error ->
        invalid!(
          "tools names #{name}/*, but config.yaml configures no server #{name}" <>
            configured_servers(configured)
        )
    end
  end

  # Whether the agent `id` can reach the server `ref`: one serving its org.
  defp reach(%Wardrik.AgentID{org: org}, ref, opts) do
    case Keyword.get(opts, :orgs, :all) do
      :all -> :ok
      orgs -> if org in orgs, do: :ok, else: {:error, not_served(ref, orgs, org)}
    end
  end

  defp not_served(ref, orgs, org),
    do: "config.yaml's #{ref} serves #{Enum.join(orgs, ", ")}, and not #{org}"

  defp configured_servers(configured) when map_size(configured) == 0, do: ""

  defp configured_servers(configured),
    do:
      ["; it has ", Enum.map_join(configured, ", ", fn {name, _ref} -> name end)]
      |> IO.iodata_to_binary()

  # -- schedules -------------------------------------------------------------

  defp schedules(nil, _files?), do: []
  defp schedules(%{} = one, files?), do: schedules([one], files?)

  defp schedules(list, files?) when is_list(list) do
    schedules = list |> Enum.with_index(1) |> Enum.map(&schedule!(&1, files?))

    case schedules -- Enum.uniq_by(schedules, & &1.name) do
      [] -> schedules
      [twice | _] -> invalid!("schedule names #{twice.name} twice")
    end
  end

  defp schedules(_other, _files?), do: invalid!("schedule is a schedule, or a list of them")

  defp schedule!({%{} = fields, index}, files?) do
    case Map.keys(fields) -- @schedule_keys do
      [] ->
        :ok

      [key | _] ->
        invalid!(
          "schedule #{key} is not a setting; expected one of #{Enum.join(@schedule_keys, ", ")}"
        )
    end

    name = optional_string!(fields["name"], "schedule name") || "schedule-#{index}"

    with {:ok, fields} <- prompted(fields, name, files?),
         {:ok, schedule} <- Wardrik.Schedule.decode(name, Map.delete(fields, "name")) do
      schedule
    else
      {:error, message} -> invalid!("schedule #{fields["name"] || index}: #{message}")
    end
  end

  defp schedule!({_other, index}, _files?),
    do: invalid!("schedule #{index} is not a set of keys")

  # A schedule's prompt_file is a prompt asking the agent to follow the file,
  # which it reads with read_file as the turn runs, so it reads it as it
  # stands then, and its taint with it.
  defp prompted(%{"prompt_file" => _file, "prompt" => _prompt}, _name, _files?),
    do: {:error, "a schedule has a prompt or a prompt_file, not both"}

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

  defp route(nil, _org), do: nil
  defp route(target, org) when is_binary(target), do: route(%{"to" => [target]}, org)
  defp route(targets, org) when is_list(targets), do: route(%{"to" => targets}, org)

  defp route(%{} = fields, org) do
    case Map.keys(fields) -- ~w(to on) do
      [] -> :ok
      [key | _] -> invalid!("notify #{key} is not a setting; expected to or on")
    end

    targets = fields |> Map.get("to") |> List.wrap()
    if targets == [], do: invalid!("notify names no target")

    %WardrikNotify.Route{
      targets: Enum.map(targets, &target!(&1, org)),
      on: fields |> Map.get("on", ~w(parked failed)) |> List.wrap() |> Enum.map(&kind!/1)
    }
  end

  defp route(_other, _org), do: invalid!("notify is a target, a list of them, or to and on")

  defp target!(name, org) when is_binary(name) do
    names = Enum.map(WardrikNotify.Config.targets(), fn {key, _target} -> key end)

    case Enum.find(names, &(Atom.to_string(&1) == name)) do
      nil ->
        invalid!(
          IO.iodata_to_binary([
            "notify names #{name}, but config.yaml's notify has no target #{name}",
            known_targets(names)
          ])
        )

      target ->
        if not WardrikNotify.Config.tells?(target, org),
          do: invalid!("notify names #{name}, which config.yaml's notify keeps for another org")

        target
    end
  end

  defp target!(name, _org), do: invalid!("notify names #{inspect(name)}, which is not a target")

  defp known_targets([]), do: []

  defp known_targets(names),
    do: ["; it has " | Enum.map_intersperse(names, ", ", &Atom.to_string/1)]

  defp kind!(kind) do
    case Enum.find(WardrikNotify.Route.kinds(), &(Atom.to_string(&1) == kind)) do
      nil -> invalid!("notify on lists #{inspect(kind)}; expected parked, failed or finished")
      found -> found
    end
  end

  # -- scalars ---------------------------------------------------------------

  defp policy(nil, _policies, _modules?), do: []

  defp policy(name, policies, modules?) when is_binary(name) do
    case Map.fetch(policies, name) do
      {:ok, policy} ->
        WardrikPolicy.hooks(policy)

      :error when modules? ->
        module = module!(name, :call, 2, "a hook", "a policy in policies/")
        [Wardrik.Hook.new(name, module)]

      :error ->
        invalid!("policy names #{name}, which is not a policy in policies/")
    end
  end

  defp policy(fields, _policies, _modules?) when is_map(fields) do
    case WardrikPolicy.decode(fields) do
      {:ok, policy} -> WardrikPolicy.hooks(policy)
      {:error, message} -> invalid!("policy " <> message)
    end
  end

  defp policy(_value, _policies, _modules?),
    do: invalid!("policy is the name of a policy, rules, or a module")

  defp module!(name, function, arity, what, known) do
    module = Module.safe_concat([name])

    if Code.ensure_loaded?(module) and function_exported?(module, function, arity),
      do: module,
      else: invalid!("#{name} is not #{what}")
  rescue
    ArgumentError -> invalid!("names #{name}, which is neither #{known} nor a module")
  end

  defp compaction(config, %{"compaction" => false}), do: Keyword.put(config, :compaction, nil)

  defp compaction(config, %{"compaction" => %{} = fields}) do
    case Map.keys(fields) -- ~w(at keep window) do
      [] ->
        Keyword.put(
          config,
          :compaction,
          Wardrik.Compaction.new(
            at: share!(fields, "at", 0.6),
            keep: share!(fields, "keep", 0.25),
            window: window!(fields["window"])
          )
        )

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

  defp iterations!(n) when is_integer(n) and n > 0, do: n
  defp iterations!("infinity"), do: :infinity
  defp iterations!(_n), do: invalid!("max_iterations is a whole number, or infinity")

  defp string!(value, _key) when is_binary(value), do: value
  defp string!(_value, key), do: invalid!("#{key} is a string")

  defp optional_string!(nil, _key), do: nil

  defp optional_string!(value, _key) when is_binary(value) or is_integer(value),
    do: to_string(value)

  defp optional_string!(_value, key), do: invalid!("#{key} is a string")

  defp invalid!(message), do: throw({:invalid, message})
end
