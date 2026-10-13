defmodule WardrikDaemon.AgentFile do
  @moduledoc """
  Reads an agent file, one in `agents/` under the config directory, into the
  `WardrikDaemon.Definition` it writes, and builds the `Wardrik.Agent.Spec`
  a definition writes.

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
  | `workspace` | the trees it shares with other agents, under `shared`; see below |
  | `context` | the files read into each turn; see below |
  | `policy` | what its tool calls may do; see below |
  | `timeout` | how many seconds a turn may take |
  | `idle_timeout` | how many seconds it may have nothing to do before it sleeps, or `infinity`; `config.yaml`'s `defaults` when absent, and 900 where they set none. A sleeping agent wakes when something asks it; see `Wardrik.Agent` |
  | `max_iterations` | how many rounds of tool calls a turn may make, or `infinity` |
  | `retries` | how many seconds a turn waits before asking a failed model call again, one wait for each try; see below |
  | `compaction` | when it summarises its older history, as `at`, `keep` and `window`; see `Wardrik.Compaction`. `false` never does |
  | `triggers` | when it is asked something on a clock, or by a webhook; see below |
  | `notify` | who hears when it parks, fails or answers; see below |
  | `channels` | the chat channels it may be chosen to answer in; see below |

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
    * `self/*`, the agent's operations on itself, as `Wardrik.Catalog.Self`
      describes them: reading its snapshot and definition, defining itself
      again, and setting and removing its own triggers, so it can change
      what it watches. An agent its file declares keeps the definition and
      triggers its file writes
    * `agents/*`, its operations on the agents of its org, as
      `Wardrik.Catalog.Agents` describes them, so it can delegate; see
      below
    * `*`, every tool the daemon ships, the file tools, every MCP server
      the agent can reach, every tool worker's tools, and its operations on
      itself and on the agents of its org
    * a module implementing `Wardrik.Tool`

  An agent reaches an MCP server that serves its org, as the server's `org`
  in `config.yaml` says. A file naming a server its agent cannot reach does
  not read, and says why.

  ## Delegating

  `agents/*` lets the agent work with the other agents of its org, each
  named by the `agent` its tools take, as `reconciler`, or `@jon/reconciler`
  for one that works for a user:

  | Tool | Does |
  | --- | --- |
  | `agents_list` | lists the agents of the org, and what each is doing |
  | `agent_read` | reads one's snapshot: its status, what it waits on, its conversation |
  | `agent_definition_read` | reads one's definition |
  | `agent_ask` | sends one a message, whose answer comes back later |
  | `agent_define` | defines one, a worker, from a whole definition, or defines it again |
  | `agent_trigger_set`, `agent_trigger_remove` | changes one's triggers |

  An agent that asks another something goes on with its turn. Once the turn
  that takes the message ends, the answer comes back to it as a message from
  that agent, holding the labels of what it read: after a delegate has read
  content from outside, so has the agent that hears its answer. A delegate
  whose turn fails, or is stopped, says so instead; one waiting on a person
  answers once someone decides. See "Answering another agent" in
  `Wardrik.Agent`.

  An agent defined this way is held to the policies and budget of the agent
  that defined it, ahead of its own definition's, so a worker is never
  looser than the agent that made it; it runs as an agent defined over HTTP
  does, and a file's agent refuses to be defined again. Asking and defining
  wait on a person, as every change does, unless the policy allows them:

      tools: [agents/*]
      policy:
        allow: [agent_ask]

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
  does not read. A conversation of the agent, one with an external ID, works
  in the agent's own tree, so what one thread keeps the next finds.

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

  A file read into the turn labels it from its start with the labels of what
  the turns that wrote it had read, such as content from outside. See
  `WardrikWorkspace.Context`.

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
  tool worker, it carries the label `outside`, there and in every turn after
  it, until `wardrik clear` empties the agent's conversation, and its `allow`
  rules stop counting for a gated tool's calls: each waits on a person, who
  sees what it would do. An `allow_after` rule for the label still counts,
  for a tool whose calls may follow what a stranger wrote:

      policy:
        allow: [linear/*]
        allow_after:
          outside: [github/add_labels]

  See `WardrikPolicy`. A definition over HTTP cannot write one in place,
  though it may name a policy in `policies/` that has one.

  ## Retries

  A model call that fails for a passing reason, such as a timeout, a dropped
  connection or a provider's 5xx, is asked again after each wait `retries`
  lists, in seconds, before the turn fails; see `Wardrik.LLM.Retry`.

      retries: [2, 10, 30]    # after 2s, then 10s, then 30s
      retries: []             # never ask again

  `config.yaml`'s `defaults` when absent, and `[1, 5]` where they set none.

  ## Triggers

  `triggers` is one trigger or a list of them, each a `WardrikTrigger`,
  that ask the agent, and none of its conversations, on a clock, when a
  feed it watches has something new, or when a service sends it a webhook:

      triggers:
        - name: sweep
          every: "*/30 * * * *"
          prompt: Check the incident queue.
        - name: digest
          every: "0 17 * * 1-5"
          prompt: Write up what happened today.
          overlap: queue
        - name: rivals
          every: 1h
          feed: [https://rivalco.example/changelog.rss, https://hnrss.org/newest?q=rivalco]
          prompt: What changed at our competitors?
        - name: issues
          webhook:
            secret: ${ISSUES_HOOK_SECRET}
          prompt: An event is below. Triage it.

    * `every` - a cron expression in UTC, quoted, since YAML reads a leading
      `*` as something else; or a duration of at least a minute, as `30m`,
      `2h` or `1d`. A `webhook` trigger has none
    * `prompt` - what the agent is asked
    * `prompt_file` - in place of `prompt`, a file in its workspace: each time
      the trigger fires the agent is asked to read it and do what it says,
      so the agent can edit the checklist it follows. It needs `files` in
      `tools`
    * `name` - the trigger's name, `trigger-1`, `trigger-2` and so on by
      its place in the list when absent
    * `overlap` - `skip` leaves an agent that is running or waiting on a
      person be, and `queue` asks it anyway; `skip` by default, and `queue`
      for a `webhook` trigger
    * `missed` - `run_once`, the default, fires once for runs missed while
      the daemon was down, and `skip` lets them go
    * `jitter` - up to this many seconds added to each run
    * `feed` - an RSS or Atom feed's URL, or a list of them, read on each
      run: the agent is asked only when one has entries it has not seen,
      with them under the prompt, as `WardrikTrigger.Feed` reads them. The
      first run only notes what a feed already holds
    * `webhook` - a service sends it requests in place of a clock, with its
      own settings: `secret`, the secret the service holds, as `${NAME}`,
      read for the agent as a tool's credential is, the vault's for its
      user, org or deployment, else the environment; and `verify`, `shared`
      by default, where a request presents the secret as a bearer token or
      at the end of its path, or `standard`, where it is signed as the
      Standard Webhooks spec says. The service sends them to
      `config.yaml`'s `base_url` and `/v1/hooks/{key}/{name}`, and the agent
      is asked about each once, with its body under the prompt, as
      `WardrikTrigger.Webhook` reads it

  ## Channels

  `channels` lists the channels of `config.yaml`'s `channels` the agent is
  offered in. Inviting a channel's bot into a room then offers it there, as
  `WardrikChannel.Rooms` describes, where the channel serves the agent's org:

      channels: [slack]

  ## Notify

  `notify` routes the agent's notices to targets `config.yaml`'s `notify`
  section names, as `WardrikNotify` describes them:

      notify: ops                      # parked and failed turns, to ops
      notify: [ops, audit]
      notify: {to: [ops], on: [parked, failed, finished]}

  `on` lists what is sent: `parked`, `failed`, and `finished` for what a turn
  answered. A target tells the agents of the org its `org` in `config.yaml`
  names, and a file routing to one for another org does not read. A
  definition sent over HTTP takes `notify` too, and means the same by it.

  The agent resolves the credentials its tools name from `WardrikVault`: its
  user's, its org's or the deployment's, and an account its user, or its
  org, connects through `WardrikOAuth` where a provider is named for one
  nobody holds. It records every tool call in `Wardrik.Ledger.Store`, so a
  turn lost part way through runs no call twice.

  ## Over HTTP

  `define/3` reads the body of `PUT /v1/agents/{id}` into a definition, for
  `WardrikHTTP` through `WardrikDaemon.Agents`, and `spec/3` builds its spec
  as it does a file's:

      {"description": "Watches the incident queue.",
       "instructions": "You watch the incident queue.",
       "model": "anthropic:claude-sonnet-5",
       "tools": ["web_search", "linear/*"],
       "policy": {"ask": ["linear/*"]}}

  `wardrik_protocol`'s `agent_definition.json` is its schema. `instructions` is
  the system prompt, as a file's body is, and the other keys mean what they
  mean in a file. The ID gives the agent's `name`, `org` and `user`. Its
  `triggers` lists the agent's triggers as a file's does, and
  `put_trigger/3` and `delete_trigger/2` change one of them in a definition
  kept, for the triggers routes. Its `tools` and
  `policy` name what the daemon ships or configures, and never a module,
  and its `workspace` shares only the trees the scope of the token that
  sent it covers.

  ## Written by wardrik

  `wardrik init` and `wardrik agent spawn` write a file here: the frontmatter
  they choose, such as `config.yaml`'s `defaults`, and a short prompt to edit
  into what the agent is for.
  """

  alias Wardrik.Agent.Spec
  alias Wardrik.AgentID
  alias WardrikDaemon.Agents
  alias WardrikDaemon.Config
  alias WardrikDaemon.Definition

  @shipped [WardrikBrave.WebSearch, WardrikResearch.Deep, WardrikLua.Run]

  @doc """
  What a definition may name here, as `WardrikDefinition` reads it: the tools
  the daemon ships, and the MCP servers, channels and notify targets
  `config.yaml` configures, with `policies` the policies in `policies/`, by
  name.
  """
  @spec context(%{String.t() => WardrikPolicy.t()}) :: WardrikDefinition.Context.t()
  def context(policies \\ %{}) do
    %WardrikDefinition.Context{
      org: Config.org(),
      tools: @shipped,
      servers: WardrikMCP |> Config.settings() |> Keyword.get(:servers, []),
      mcp: WardrikMCP,
      sources: [
        workers: WardrikHTTP.Workers,
        self: Wardrik.Catalog.Self,
        agents: Wardrik.Catalog.Agents
      ],
      channels: WardrikChannel |> Config.settings() |> Keyword.get(:orgs, []),
      targets: WardrikNotify |> Config.settings() |> Keyword.get(:targets, []),
      policies: policies,
      defaults: Agents.defaults(),
      seams: [credentials: WardrikVault, ledger: Wardrik.Ledger.Store],
      config: [tool_prices: Keyword.get(Config.settings(__MODULE__), :tool_prices, %{})],
      names: %{host: "the daemon", config: "config.yaml", policies: "policies/"}
    }
  end

  @doc """
  An agent file with `fields` as its frontmatter, in the order given, and a
  short prompt after it; see `WardrikDefinition.text/1`.
  """
  @spec text([{String.t(), term()}]) :: String.t()
  def text(fields), do: WardrikDefinition.text(fields)

  @doc """
  Reads the spec of the agent `path` declares, with `policies` the policies in
  `policies/`, by name.
  """
  @spec read(Path.t(), %{String.t() => WardrikPolicy.t()}) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def read(path, policies \\ %{}) do
    with {:ok, definition} <- parse(path) do
      case spec(definition, definition.id, policies) do
        {:ok, spec} -> {:ok, spec}
        {:error, message} -> {:error, "#{path}: #{message}"}
      end
    end
  end

  @doc """
  The `WardrikDaemon.Definition` the agent file `path` writes: its frontmatter,
  with its body as `instructions`, for the agent its `name`, `org` and `user`
  name. What its settings say is checked as `spec/3` builds a spec from it.
  """
  @spec parse(Path.t()) :: {:ok, Definition.t()} | {:error, String.t()}
  def parse(path) do
    name = path |> Path.basename() |> Path.rootname()

    with {:ok, text} <- File.read(path),
         {:ok, id, fields} <- WardrikDefinition.parse(text, name, context()) do
      {:ok, %Definition{id: id, fields: fields, source: {:file, Path.basename(path)}}}
    else
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      {:error, message} -> {:error, "#{path}: #{message}"}
    end
  end

  @doc """
  The `WardrikDaemon.Definition` a definition sent to the HTTP API writes for
  the agent `id`, sent by a token holding `grant`, or by none for
  `config.yaml`'s `defaults`. What its settings say is checked as `spec/3`
  builds a spec from it, the trees its workspace shares against the grant's
  scope among them.
  """
  @spec define(AgentID.t(), map(), Wardrik.Grant.t() | nil) ::
          {:ok, Definition.t()} | {:error, String.t()}
  def define(%AgentID{} = id, fields, grant) when is_map(fields) do
    with :ok <- WardrikDefinition.accept(id, fields, context()),
         do: {:ok, %Definition{id: id, fields: fields, source: {:api, grant}}}
  end

  @doc """
  Reads a definition sent to the HTTP API for the agent `id` into its spec,
  as `define/3` and `spec/3` do, sent by no token.
  """
  @spec definition(AgentID.t(), map(), %{String.t() => WardrikPolicy.t()}) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def definition(%AgentID{} = id, fields, policies \\ %{}) do
    with {:ok, definition} <- define(id, fields, nil), do: spec(definition, id, policies)
  end

  @doc """
  The spec `definition` writes for the agent `id`, with `policies` as `read/2`
  takes them; see `WardrikDefinition.spec/5`.
  """
  @spec spec(Definition.t(), AgentID.t(), %{String.t() => WardrikPolicy.t()}) ::
          {:ok, Spec.t()} | {:error, String.t()}
  def spec(%Definition{id: owner, fields: fields, source: source}, %AgentID{} = id, policies),
    do: WardrikDefinition.spec(fields, owner, id, context(policies), source)

  @doc """
  Where the notices of `definition`'s agent go, whether a file or the HTTP
  API wrote it, to the targets `config.yaml`'s `notify` keeps for its org;
  see `WardrikDefinition.route/3`.
  """
  @spec route(Definition.t()) :: {:ok, WardrikNotify.Route.t()} | :none | {:error, String.t()}
  def route(%Definition{id: id, fields: fields}),
    do: WardrikDefinition.route(fields, id, context())

  @doc "The definition as the HTTP API writes one; see `WardrikDefinition.fields/1`."
  @spec fields(Definition.t()) :: map()
  def fields(%Definition{fields: fields}), do: WardrikDefinition.fields(fields)

  @doc "The triggers `definition` lists; see `WardrikDefinition.triggers/1`."
  @spec triggers(Definition.t()) :: [WardrikTrigger.trigger()]
  def triggers(%Definition{fields: fields}), do: WardrikDefinition.triggers(fields)

  @doc """
  `definition` with the trigger `name` set to `given`; see
  `WardrikDefinition.put_trigger/3`.
  """
  @spec put_trigger(Definition.t(), String.t(), map()) ::
          {:ok, Definition.t(), :created | :changed, WardrikTrigger.trigger()}
          | {:error, String.t()}
  def put_trigger(%Definition{fields: fields} = definition, name, given) do
    with {:ok, fields, status, trigger} <- WardrikDefinition.put_trigger(fields, name, given),
         do: {:ok, %{definition | fields: fields}, status, trigger}
  end

  @doc "`definition` without the trigger `name`, or `{:error, :not_found}` where it has none."
  @spec delete_trigger(Definition.t(), String.t()) ::
          {:ok, Definition.t()} | {:error, :not_found}
  def delete_trigger(%Definition{fields: fields} = definition, name) do
    with {:ok, fields} <- WardrikDefinition.delete_trigger(fields, name),
         do: {:ok, %{definition | fields: fields}}
  end

  @doc "The channels a definition's fields offer its agent in, by name."
  @spec channels(map()) :: [String.t()]
  def channels(fields), do: WardrikDefinition.channels(fields)
end
