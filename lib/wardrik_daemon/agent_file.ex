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
  | `name` | its name, and with `org` and `user` its key in the fleet. The file's name without `.md` when absent |
  | `description` | what it is for, as `wardrik status` shows it |
  | `model` | the model, as `provider:model`. `Wardrik.LLM.Config`'s default when absent |
  | `tools` | what it may call; see below |
  | `workspace` | the trees it shares with other agents, under `shared`; see below. A definition over HTTP cannot say it |
  | `context` | the files read into each turn; see below. A definition over HTTP cannot say it |
  | `org`, `user` | who it works for |
  | `policy` | what its tool calls may do; see below |
  | `timeout` | how many seconds a turn may take |
  | `max_iterations` | how many rounds of tool calls a turn may make, or `infinity` |
  | `compaction` | when it summarises its older history, as `at`, `keep` and `window`; see `Wardrik.Compaction`. `false` never does |
  | `trust_outside_content` | `true` lets its rules allow a gated tool's calls even after a turn has read content from outside; see below. A definition over HTTP cannot say it |
  | `schedule` | when it is asked something on a clock; see below |
  | `notify` | who hears when it parks, fails or answers; see below |

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
      connected, and every tool worker's tools
    * a module implementing `Wardrik.Tool`

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
  tool worker, its rules stop counting for a gated tool's calls until the turn
  ends: each waits on a person, who sees what it would do.
  `trust_outside_content: true` is for an agent whose job is to act on what
  strangers send.

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
  answered.

  The agent is given the credentials `WardrikOAuth` holds where a provider is
  configured, and `WardrikVault`'s where the vault has a key, and records every
  tool call in `Wardrik.Ledger.Store`, so a turn lost part way through runs no
  call twice.

  ## Over HTTP

  `definition/3` reads the body of `PUT /v1/agents/{org}/{user}/{name}` into
  a spec the same way, for `WardrikHTTP` through `WardrikDaemon.Agents`:

      {"description": "Watches the incident queue.",
       "instructions": "You watch the incident queue.",
       "model": "anthropic:claude-sonnet-5",
       "tools": ["web_search", "linear/*"],
       "policy": {"ask": ["linear/*"]}}

  `priv/protocol/v1/agent_definition.json` is its schema. `instructions` is
  the system prompt, as a file's body is, and the other keys mean what they
  mean in a file. The key gives the agent's `name`,
  `org` and `user`. A definition has no `schedule` or `notify`: it leaves the
  agent's schedules as they are, and the schedules routes set them. Its
  `tools` and `policy` name what the daemon ships or configures, and never a
  module.
  """

  alias Wardrik.Agent.Spec
  alias Wardrik.LLM.Config
  alias WardrikPolicy.Pattern

  @shipped [WardrikBrave.WebSearch, WardrikResearch.Deep, WardrikLua.Run]
  @keys ~w(name description model tools workspace context org user policy timeout max_iterations compaction trust_outside_content schedule notify)
  @definition_keys ~w(description instructions model tools policy timeout max_iterations compaction)
  @schedule_keys ~w(name every prompt prompt_file overlap missed jitter)

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
  Reads a definition sent to the HTTP API for the agent under `key` into its
  spec, with `policies` as `read/2` takes them. The spec's `schedules` is
  `nil`, so `Wardrik.Fleet.put/1` leaves the agent's schedules as they are.
  """
  @spec definition(String.t(), map(), %{String.t() => WardrikPolicy.t()}) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def definition(key, fields, policies \\ %{}) when is_binary(key) and is_map(fields) do
    known!(fields, @definition_keys)
    {org, user, name} = Wardrik.Fleet.parse(key)
    instructions = optional_string!(fields["instructions"], "instructions") || ""

    {:ok,
     spec(fields, instructions, policies, false,
       name: name,
       org: org,
       user: user,
       schedules: nil
     )}
  rescue
    error in [ArgumentError] -> {:error, Exception.message(error)}
  catch
    {:invalid, message} -> {:error, message}
  end

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

    spec =
      spec(fields, body, policies, true,
        name:
          optional_string!(fields["name"], "name") || path |> Path.basename() |> Path.rootname(),
        org: optional_string!(fields["org"], "org"),
        user: optional_string!(fields["user"], "user"),
        schedules: schedules(fields["schedule"], files?(fields))
      )

    {:ok, spec, route(fields["notify"])}
  rescue
    error in [ArgumentError] -> {:error, "#{path}: #{Exception.message(error)}"}
  end

  defp known!(fields, keys) do
    case Map.keys(fields) -- keys do
      [] -> :ok
      [key | _] -> invalid!("#{key} is not a setting; expected one of #{Enum.join(keys, ", ")}")
    end
  end

  # Everything a file and a definition say alike, with `identity` the fields
  # each gives its own way. `modules?` lets `tools` and `policy` name modules.
  defp spec(fields, system, policies, modules?, identity) do
    key = Wardrik.Fleet.key(identity[:name], org: identity[:org], user: identity[:user])

    config =
      [system: if(system == "", do: nil, else: system), tools: tools(fields, modules?, key)]
      |> put(:model_spec, fields["model"], &string!(&1, "model"))
      |> put(:max_iterations, fields["max_iterations"], &iterations!/1)
      |> put(:trust_outside_content, fields["trust_outside_content"], &trust!/1)
      |> compaction(fields)
      |> Config.new()

    Spec.new(
      identity ++
        [
          description: optional_string!(fields["description"], "description"),
          config: config,
          hooks: policy(fields["policy"], policies, modules?),
          timeout: fields["timeout"] && seconds!(fields["timeout"]),
          credentials: credentials(),
          ledger: Wardrik.Ledger.Store
        ]
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

  defp tool!("*", _modules?, key), do: @shipped ++ [{WardrikMCP, :*}, {WardrikHTTP.Workers, key}]
  defp tool!("workers/*", _modules?, key), do: [{WardrikHTTP.Workers, key}]

  defp tool!("workers/" <> tool = name, _modules?, _key) do
    invalid!(
      "tools names #{name}; name the workers' tools as workers/*, and let a policy deny what is not #{tool}"
    )
  end

  defp tool!(name, modules?, _key) when is_binary(name) do
    pattern = Pattern.parse!(name)

    cond do
      Pattern.argument?(pattern) ->
        invalid!(
          "tools names #{name}; name the tool alone, and let a policy name what its calls act on"
        )

      server = Pattern.server(pattern) ->
        [server!(server)]

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

  defp server!(name) do
    configured = Map.new(WardrikMCP.Config.refs(), &{Atom.to_string(&1), &1})

    case Map.fetch(configured, name) do
      {:ok, ref} ->
        {WardrikMCP, ref}

      :error ->
        invalid!(
          "tools names #{name}/*, but config.yaml configures no server #{name}" <>
            configured_servers(configured)
        )
    end
  end

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

  defp route(nil), do: nil
  defp route(target) when is_binary(target), do: route(%{"to" => [target]})
  defp route(targets) when is_list(targets), do: route(%{"to" => targets})

  defp route(%{} = fields) do
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

  defp route(_other), do: invalid!("notify is a target, a list of them, or to and on")

  defp target!(name) when is_binary(name) do
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
        target
    end
  end

  defp target!(name), do: invalid!("notify names #{inspect(name)}, which is not a target")

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

  defp trust!(trust) when is_boolean(trust), do: trust
  defp trust!(_trust), do: invalid!("trust_outside_content is true or false")

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

  defp credentials do
    cond do
      WardrikOAuth.Config.configured?() -> WardrikOAuth
      WardrikVault.ready?() -> WardrikVault
      true -> nil
    end
  end

  defp invalid!(message), do: throw({:invalid, message})
end
