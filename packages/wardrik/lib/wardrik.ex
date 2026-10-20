defmodule Wardrik do
  @moduledoc """
  Agents inside your Elixir app. Define an instance once, start it in your
  supervision tree, and call it as your users.

      defmodule MyApp.Agents do
        use Wardrik, otp_app: :my_app

        @impl Wardrik
        def principal(%MyApp.Accounts.User{org: org, id: id, email: email}),
          do: %{org: org, id: id, name: email}
      end

  Tell it where to keep everything, in `config/runtime.exs`:

      config :my_app, MyApp.Agents, store: [repo: MyApp.Repo]

  Then start it after your Repo:

      children = [MyApp.Repo, MyApp.Agents, MyAppWeb.Endpoint]

  Now act as a user:

      maria = %MyApp.Accounts.User{org: "acme", id: 42, email: "maria@acme.example"}

      {:ok, _snapshot} =
        MyApp.Agents.define(maria, "support",
          model: "anthropic:claude-sonnet-5",
          instructions: "Answer questions about orders in two sentences."
        )

      {:ok, _message} = MyApp.Agents.ask(maria, "support", "Where is order 1001?")

  Notice `"support"` is Maria's own agent. Nobody else reaches it unless
  your `c:grants/1` says so.

  ## Who may do what

  `c:principal/1` says who a user is. `c:grants/1` says what they may do,
  as roles. Each user owns their own agents and accounts by default:

      @impl Wardrik
      def grants(%{org: _org, id: _id}), do: [owner: :own, reader: :org, messenger: :org]

  | Role | May |
  | --- | --- |
  | `reader` | read agents, their events and their definitions |
  | `messenger` | ask, cancel and clear |
  | `approver` | decide the calls agents wait on |
  | `definer` | define, start, stop and forget agents, and add servers and accounts |
  | `owner` | everything |

  `:own` is the user's own agents and accounts. `:org` is their org's
  agents. The functions that take no user, such as `c:reload/0`, act as your
  app itself.

  ## Naming agents

  | You pass | The agent |
  | --- | --- |
  | `"support"` | the user's own `support` |
  | `{:org, "triage"}` | their org's `triage` |

  ## Config

  #{NimbleOptions.docs(Wardrik.Instance.schema())}

  ## What it starts

  The instance starts its store, then the agents, the meters budgets count,
  the triggers, and each plugin's children in order, under `:rest_for_one`:
  a restart restarts everything after it.

  ## Limits

  One instance per node.

  ## Underneath

  The functions below take a `Wardrik.Scope` instead of a user. An instance
  calls them for you. The HTTP API and the daemon call them directly.
  """

  use Supervisor

  require Logger

  alias Wardrik.Agent
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.AgentAddress
  alias Wardrik.AgentID
  alias Wardrik.Audit
  alias Wardrik.Connections
  alias Wardrik.Connections.Connection
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Deployment.Nodes
  alias Wardrik.Error
  alias Wardrik.Event.Cursor
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Fleet
  alias Wardrik.Fleet.Member
  alias Wardrik.Forgetting
  alias Wardrik.Host
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Moving
  alias Wardrik.Principal
  alias Wardrik.Reply
  alias Wardrik.Resource
  alias Wardrik.Scope
  alias Wardrik.Servers
  alias Wardrik.Servers.Server
  alias Wardrik.Spawned
  alias Wardrik.Statement
  alias Wardrik.Thread
  alias Wardrik.Token
  alias Wardrik.Tokens
  alias Wardrik.Wait
  alias Wardrik.Waiting
  alias WardrikDefinition.Context

  @typedoc "A decision on a call an agent waits on."
  @type decision() :: :approve | {:approve, String.t()} | {:deny, String.t()}

  @typedoc "What deciding answers: the decisions taken, or with `wait:`, how the run ended."
  @type decided() ::
          {:ok, %{String.t() => decision()} | Reply.t()}
          | {:waiting, Waiting.t()}
          | {:error, Error.t()}

  @typedoc "What became of an agent a forget reached: removed, kept with why, or not removed with why."
  @type outcome() :: :forgotten | {:kept, String.t()} | {:failed, String.t()}

  # -- use Wardrik -------------------------------------------------------------------

  @typedoc "Whoever acts: your own user, as `c:principal/1` reads it."
  @type user() :: term()

  @typedoc """
  Who a user is: their org, their id in it, and the name to show where you
  have one. Neither org nor id holds `/`, whitespace, `*`, `?` or `:`, nor
  begins with `@` or `_`.
  """
  @type principal() :: %{
          required(:org) => String.t() | atom() | integer(),
          required(:id) => String.t() | atom() | integer(),
          optional(:name) => String.t()
        }

  @typedoc "A user as `c:grants/1` is handed them: their org and id, as text."
  @type who() :: %{org: String.t(), id: String.t()}

  @typedoc """
  A role, on the user's own agents and accounts (`:own`), their org's agents
  (`:org`), or the agents a pattern names, such as `"acme/agent/*"`.
  """
  @type grant() :: {Wardrik.Role.t(), :own | :org | String.t()}

  @typedoc "An agent: the user's own by name, their org's as `{:org, name}`, or its ID."
  @type agent() :: String.t() | {:org, String.t()} | AgentAddress.t()

  @typedoc "What an agent is: a keyword list or a map, with the fields an agent file takes."
  @type fields() :: keyword() | map()

  @typedoc "What a function answers: its value, or why not."
  @type result(value) :: {:ok, value} | {:error, Error.t()}

  @doc "Who `user` is. Required."
  @doc group: "Your callbacks"
  @callback principal(user()) :: principal()

  @doc """
  What the user `who` names may do. Each user owns their own agents and
  accounts by default, `[owner: :own]`.
  """
  @doc group: "Your callbacks"
  @callback grants(who()) :: [grant()]

  @doc "The user a request to the HTTP API comes from, or `:error` to refuse it."
  @doc group: "Your callbacks"
  @callback authenticate(conn :: term()) :: {:ok, user()} | :error

  @optional_callbacks grants: 1, authenticate: 1

  @doc "Starts the instance, with `opts` over its config."
  @doc group: "Running"
  @callback start_link(opts :: keyword()) :: Supervisor.on_start()

  @doc "The instance's config, as it starts with it."
  @doc group: "Running"
  @callback config() :: keyword()

  @doc """
  Defines `agent` with `fields`, or defines it again, and answers its
  snapshot. `fields` are what an agent file takes, as a keyword list or a map:

      MyApp.Agents.define(maria, "support", model: "anthropic:claude-sonnet-5", instructions: "Be brief.")
  """
  @doc group: "Agents"
  @callback define(user(), agent(), fields(), opts :: keyword()) :: result(Snapshot.t())

  @doc "`agent`'s definition as it was last put, and the tools it names that offer nothing yet."
  @doc group: "Agents"
  @callback definition(user(), agent()) ::
              result(%{definition: Definition.t(), missing: [String.t()]})

  @doc "`agent`'s snapshot: what it is doing, what it waits on, and its conversation."
  @doc group: "Agents"
  @callback get(user(), agent()) :: result(Snapshot.t())

  @doc """
  The agents the user reaches, awake or asleep: their own, then their org's.

  #{Wardrik.Instance.options(:only)}
  """
  @doc group: "Agents"
  @callback list(user(), opts :: keyword()) :: result([Member.t()])

  @doc "Starts `agent`: one asleep wakes, and one never defined starts from your `defaults`."
  @doc group: "Agents"
  @callback start(user(), agent()) :: result(Spawned.t())

  @doc "Stops `agent` now, keeping its conversation. It wakes when something asks it."
  @doc group: "Agents"
  @callback stop(user(), agent()) :: result(Member.t())

  @doc "Empties `agent`'s conversation. Its files, triggers and config stay."
  @doc group: "Agents"
  @callback clear(user(), agent()) :: result(Snapshot.t())

  @doc "Removes `agent`, with everything it had."
  @doc group: "Agents"
  @callback forget(user(), agent()) :: :ok | {:error, Error.t()}

  @doc "Sets `agent`'s trigger `name` to `fields`, as an agent file writes one, and answers it."
  @doc group: "Agents"
  @callback put_trigger(user(), agent(), name :: String.t() | atom(), fields()) :: result(map())

  @doc "Removes `agent`'s trigger `name`, and answers it."
  @doc group: "Agents"
  @callback delete_trigger(user(), agent(), name :: String.t() | atom()) :: result(map())

  @doc """
  Sends `agent` `text` from the user, and answers the message queued. Its
  `cursor` is where the agent's log stood, so `c:events/3` after it reads
  the turn that answers it.
  """
  @doc group: "Talking to an agent"
  @callback ask(user(), agent(), text :: String.t(), opts :: keyword()) :: result(Message.t())

  @doc "Runs the call, or calls, `agent` waits on a person for. `note:` is what the agent is told."
  @doc group: "Talking to an agent"
  @callback approve(user(), agent(), calls :: String.t() | [String.t()], opts :: keyword()) ::
              result(%{String.t() => decision()})

  @doc "Refuses the call, or calls, `agent` waits on a person for. `reason:` is what the agent is told."
  @doc group: "Talking to an agent"
  @callback deny(user(), agent(), calls :: String.t() | [String.t()], opts :: keyword()) ::
              result(%{String.t() => decision()})

  @doc "Decides several calls at once, by id: `:approve`, `{:approve, note}` or `{:deny, reason}`."
  @doc group: "Talking to an agent"
  @callback decide(user(), agent(), %{String.t() => decision()}) ::
              result(%{String.t() => decision()})

  @doc """
  Every call the user's agents wait on a person for, with its agent.

  #{Wardrik.Instance.options(:only)}
  """
  @doc group: "Talking to an agent"
  @callback waiting(user(), opts :: keyword()) ::
              result([{AgentAddress.t(), {Wardrik.Tool.call(), String.t()}}])

  @doc "Where a person authorizes the call `call` that `agent` waits on."
  @doc group: "Talking to an agent"
  @callback authorization(user(), agent(), call :: String.t()) :: result(Wardrik.Call.Ask.link())

  @doc "Ends the turn `agent` is taking, and what is queued behind it."
  @doc group: "Talking to an agent"
  @callback cancel(user(), agent()) :: :ok | {:error, Error.t()}

  @doc "The tool calls `agent` is running now."
  @doc group: "Talking to an agent"
  @callback calls(user(), agent()) ::
              result([%{call_id: String.t(), name: String.t(), elapsed_ms: non_neg_integer()}])

  @doc "Stops the tool call `call` that `agent` is running. The rest of the turn goes on."
  @doc group: "Talking to an agent"
  @callback kill_call(user(), agent(), call :: String.t()) :: :ok | {:error, Error.t()}

  @doc """
  Sends this process every event `agent` writes from now on, or every agent
  the user reads, with `:all`.

  #{Wardrik.Instance.options(:subscribe)}
  """
  @doc group: "Events"
  @callback subscribe(user(), agent() | :all, opts :: keyword()) :: :ok | {:error, Error.t()}

  @doc "Stops sending this process `agent`'s events, or every agent's, with `:all`."
  @doc group: "Events"
  @callback unsubscribe(user(), agent() | :all) :: :ok

  @doc """
  `agent`'s events, or those of every agent the user reads, as a lazy stream.

  #{Wardrik.Instance.options(:events)}
  """
  @doc group: "Events"
  @callback events(user(), agent() | :all, opts :: keyword()) :: result(Enumerable.t())

  @doc """
  The MCP servers the user added.

  #{Wardrik.Instance.options(:org)}
  """
  @doc group: "Servers and accounts"
  @callback servers(user(), opts :: keyword()) :: result([Server.t()])

  @doc """
  Adds the MCP server `server`, by its `name`, `url` and `auth`, for the
  user's agents, and answers it.

  #{Wardrik.Instance.options(:org)}
  """
  @doc group: "Servers and accounts"
  @callback add_server(user(), server :: Server.t() | keyword(), opts :: keyword()) ::
              result(Server.t())

  @doc """
  Removes the MCP server `name`, and answers it as it was.

  #{Wardrik.Instance.options(:org)}
  """
  @doc group: "Servers and accounts"
  @callback remove_server(user(), name :: String.t(), opts :: keyword()) :: result(Server.t())

  @doc "The accounts the user may connect, and which they hold."
  @doc group: "Servers and accounts"
  @callback connections(user()) :: result([Connection.t()])

  @doc "Connects the user's account at `provider`, answering where to sign in where they hold none."
  @doc group: "Servers and accounts"
  @callback connect(user(), provider :: String.t()) :: result(Connection.t())

  @doc "Forgets the user's account at `provider`."
  @doc group: "Servers and accounts"
  @callback disconnect(user(), provider :: String.t()) :: result(Connection.t())

  @doc "Reads every agent's definition again, as your app."
  @doc group: "Your app"
  @callback reload() :: result(%{reloaded: [AgentID.t()], failed: [String.t()]})

  @doc "The nodes, each with how many agents run on it, and how many sleep, as your app."
  @doc group: "Your app"
  @callback nodes() :: result(Nodes.t())

  @doc "A page of the audit, what people changed, as your app: `after:` a sequence, `limit:` how many."
  @doc group: "Your app"
  @callback audit(opts :: keyword()) :: result([Entry.t()])

  @doc "Starts `agent`, by its ID, again on `node`, as your app."
  @doc group: "Your app"
  @callback move(AgentAddress.t() | String.t(), node()) :: result(Member.t())

  @doc false
  defmacro __using__(opts) do
    otp_app =
      Keyword.get(opts, :otp_app) ||
        raise ArgumentError,
              "use Wardrik takes the app whose config holds this instance's, as use Wardrik, otp_app: :my_app"

    quote do
      @behaviour Wardrik

      @doc false
      def child_spec(opts),
        do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :supervisor}

      def start_link(opts \\ []),
        do: Wardrik.Instance.start_link(__MODULE__, unquote(otp_app), opts)

      def config, do: Wardrik.Instance.config(__MODULE__, unquote(otp_app), [])

      def grants(_who), do: [owner: :own]

      defoverridable child_spec: 1, grants: 1

      unquote(Wardrik.Instance.functions())
    end
  end

  # What a thread runs on of its agent's, read and changed on the agent.
  @agents_own ~w(agent.define agent.definition.read agent.trigger.set agent.trigger.remove)

  @seams [:issuer, :credentials, :connections, :servers, :tokens, :triggers, :dispatch, :llm]

  # The setting that names each store.
  @stores [
    repo: WardrikEcto.Store,
    url: WardrikEcto.Store,
    bucket: WardrikS3.Store,
    data_dir: WardrikStore.EKV
  ]

  @doc """
  The `Wardrik.Host` `opts` describe. It starts nothing: start it with
  `{Wardrik, wardrik}`. Raises on an option not listed here, or without
  `:store`.

  ## Options

    * `:store` - where everything is kept, as `store/1` makes it. Required.
    * `:context` - what definitions may name beyond the host's tools and
      sources: `context/1`'s, or your own value implementing
      `WardrikDefinition.Contexts`, which gives each agent its own.
      `context([])` by default.
    * `:tools` - modules implementing `Wardrik.Tool`, each named by its
      tool's name. Definitions may also name `self/*`, an agent's
      operations on itself, and `agents/*`, those on the other agents of
      its org.
    * `:runtimes` - the `Wardrik.Runtime`s that run agents' turns.
      `[%Wardrik.LLM.Runtime{}]` by default.
    * `:issuer`, `:credentials`, `:connections`, `:servers`, `:tokens`,
      `:triggers`, `:dispatch`, `:llm` - the host's seams, each a value
      implementing core's protocol of that name, as `Wardrik.Host` lists
      them. A seam left out gets its protocol's default: tokens that allow
      nothing, no credentials, model calls through ReqLLM, and so on.
    * `:expires` - how long tokens last, in seconds. `api:` for those
      `tokens_create/4` makes, 90 days by default. `session:` for those
      `as/3` issues, 12 hours by default.
  """
  @spec new(keyword()) :: Host.t()
  def new(opts) do
    opts =
      Keyword.validate!(
        opts,
        [:store, :expires, :runtimes, tools: [], context: context([])] ++ @seams
      )

    store = Keyword.fetch!(opts, :store)

    [
      store: store,
      definitions: %Definitions{store: store, contexts: opts[:context]},
      workspace: %WardrikWorkspace.Backend.Store{store: store}
    ]
    |> Kernel.++(Keyword.take(opts, [:expires, :runtimes | @seams]))
    |> Host.new()
    |> Host.register(:tools, for(tool <- opts[:tools], do: {tool.tool().name, tool}))
    |> Host.register(:sources, [
      {"self", Wardrik.Catalog.Self},
      {"agents", Wardrik.Catalog.Agents}
    ])
  end

  @doc """
  The store `settings` name, made without starting anything. One of:

    * `repo: MyApp.Repo` - in Postgres, through an Ecto repo the application
      starts before Wardrik, whose table a migration of its own creates with
      `Wardrik.Migration`. `url:` names a database for a repo of the store's
      own instead.
    * `bucket: "wardrik"` - in an S3 bucket, with its `endpoint`, `region`,
      `access_key_id` and `secret_access_key`, under a `prefix`.
    * `data_dir: "/var/lib/my_app/wardrik"` - on each node's disk, for an
      application that adds `{:ekv, "~> 0.4.3"}` to its dependencies.

  `discovery_interval_ms` is how often a node looks for agents no node
  holds. Raises where `settings` name no store, or more than one.
  `:memory` keeps everything in this node's memory, for tests.

      Wardrik.store(repo: MyApp.Repo)

  The store is a value of its own, so a seam that keeps something, such as
  a vault of credentials, is made with the same one.
  """
  @spec store(keyword() | :memory) :: WardrikStore.t()
  def store(:memory), do: WardrikStore.new(adapter: WardrikStore.Memory)

  def store(settings) do
    case Enum.uniq(for {key, store} <- @stores, Keyword.has_key?(settings, key), do: store) do
      [adapter] ->
        WardrikStore.new([adapter: adapter] ++ settings)

      _none_or_several ->
        raise ArgumentError,
              "Wardrik.store/1 names one store, by repo:, url:, bucket: or data_dir:, " <>
                "and #{inspect(settings)} does not"
    end
  end

  @doc """
  What a definition may name beyond the host's tools and sources, as the
  fields of `WardrikDefinition.Context` in `fields`: the `policies`, the
  `defaults` every agent takes, and so on.

      Wardrik.context(policies: %{"careful" => policy})

  The context is a value too, so your app can give each agent a different
  one through `new/1`'s `:context`.
  """
  @spec context(keyword()) :: Context.t()
  def context(fields), do: struct!(Context, fields)

  @doc "The child that runs Wardrik on `host`, as `new/1` makes it."
  @spec child_spec(Host.t()) :: Supervisor.child_spec()
  def child_spec(%Host{} = host),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [host]}, type: :supervisor}

  @doc "Starts Wardrik on `host`, as `child_spec/1` does."
  @spec start_link(Host.t()) :: Supervisor.on_start()
  def start_link(%Host{} = host), do: Supervisor.start_link(__MODULE__, host)

  @impl true
  def init(%Host{} = host) do
    store = Host.store(host)

    children =
      [
        {Wardrik.Core, host: host},
        {WardrikPolicy.Supervisor, store: store},
        {WardrikTrigger, store: store, host: host}
      ] ++
        for({module, opts} <- Host.children(host), do: {module, Keyword.put(opts, :host, host)})

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  The scope `principal` acts in on the agents of `host`, as `new/1` makes
  it or a surface was started with: the token the host's `Wardrik.Issuer`
  issues them, which reads `opts` as it reads them, expiring as the host's
  `:session` expiry says. Each function here refreshes a token past its
  expiry through the issuer as it uses it, so whatever holds the scope
  keeps working, held to what the issuer gives the principal now (see
  `Wardrik.Token.refresh/2`).

      scope = Wardrik.as(wardrik, maria)
  """
  @doc group: "Scopes"
  @spec as(Host.t(), Principal.t(), keyword()) :: Scope.t()
  def as(%Host{} = host, principal, opts \\ []) do
    token = Wardrik.Issuer.issue(Host.issuer(host), principal, opts)
    Scope.new(host, %{token | expires: from_now(Host.expires(host, :session))})
  end

  # -- talking to an agent ----------------------------------------------------

  @ask_opts NimbleOptions.new!(
              id: [
                type: {:or, [:string, nil]},
                doc: "the message's id, which the agent takes once; a new UUIDv7 by default"
              ],
              wait: [
                type: :timeout,
                doc:
                  "how long, in milliseconds, to wait for the run that answers the message. " <>
                    "It then answers how the run ended: its `Wardrik.Reply`, or the " <>
                    "`Wardrik.Waiting` calls it stopped to ask a person about. Needs " <>
                    "`agent.events` on the agent."
              ]
            )

  @doc """
  Sends `agent` `text` from whoever acts with the scope's token, its
  `Wardrik.Token.actor/1`, which it answers in a turn of its own.
  Acknowledged with the `Wardrik.Agent.Message` queued, whose `cursor` is
  where the agent's log stood: the turn that answers it is written after
  it, so `events/2` after it reads that turn. An agent's scope, as
  `Wardrik.Scope.agent/2` makes it, is answered back.

  With `wait:`, it answers how the run that answers the message ended:

      case Wardrik.agent_ask(scope, agent, "Where is order 1001?", wait: :timer.seconds(30)) do
        {:ok, %Wardrik.Reply{text: text}} -> text
        {:waiting, %Wardrik.Waiting{calls: calls}} -> calls
        {:error, %Wardrik.Error{type: :timeout}} -> "Still working on it."
      end

  A run that fails or is stopped answers a `:failed` or `:cancelled` error.

  ## Options

  #{NimbleOptions.docs(@ask_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_ask(Scope.t(), AgentAddress.t(), String.t(), keyword()) ::
          {:ok, Message.t() | Reply.t()} | {:waiting, Waiting.t()} | {:error, Error.t()}
  def agent_ask(%Scope{} = scope, agent, text, opts \\ [])
      when is_binary(text) do
    opts = NimbleOptions.validate!(opts, @ask_opts)

    with :ok <- said(text, opts[:id]),
         :ok <- authorize(scope, "agent.ask", agent) do
      case opts[:wait] do
        nil -> asked(scope, agent, text, opts[:id])
        ms -> asked_then(scope, agent, text, opts[:id], ms)
      end
    end
  end

  defp asked(scope, agent, text, id) do
    with {:ok, %Snapshot{cursor: cursor}} <- agent_snapshot(agent, scope.host) do
      message = Message.new(text, id, sender: Token.actor(scope.token), reply_to: scope.reply_to)
      message = %{message | cursor: cursor}

      case Agent.queue(agent, message, host: scope.host) do
        :ok -> {:ok, message}
        {:error, :not_found} -> {:error, Error.no_agent(agent)}
      end
    end
  end

  defp asked_then(scope, agent, text, id, ms) do
    with :ok <- authorize(scope, "agent.events", agent),
         {:ok, message} <- asked(scope, agent, text, id),
         do: Wait.answer(Host.store(scope.host), agent, message.cursor, {:asked, message.id}, ms)
  end

  defp said("", _id), do: {:error, Error.new(:invalid, "A message has text to send")}
  defp said(_text, ""), do: {:error, Error.new(:invalid, "A message's id is text")}
  defp said(_text, _id), do: :ok

  # -- events ------------------------------------------------------------------

  @following [
    resources: [
      type: {:list, {:struct, Resource}},
      doc:
        "the agents, as `Wardrik.Resource` patterns, as `acme/agent/*`, each of which the " <>
          "scope's token allows `agent.events` on whole; those it allows it on by default"
    ],
    types: [
      type: {:list, :string},
      doc: "the CloudEvent types it takes, as `\"wardrik.run.completed\"`; every type by default"
    ]
  ]

  @events_opts NimbleOptions.new!(
                 @following ++
                   [
                     after: [
                       type: {:or, [:string, {:in, [:head]}]},
                       default: "",
                       doc:
                         "the cursor it reads after, as `cursor/2` moves it, or `:head` to read " <>
                           "nothing and take what is written from now, as from `events_head/2`'s " <>
                           "cursor; every event by default"
                     ],
                     follow: [
                       type: :boolean,
                       default: false,
                       doc: "whether it goes on to take each entry as it is written"
                     ]
                   ]
               )

  @subscribe_opts NimbleOptions.new!(@following)
  @resources_opts NimbleOptions.new!(Keyword.take(@following, [:resources]))

  @doc """
  Sends this process each event the agents `:resources` covers write from
  now on, durable and live, as `Wardrik.Event` structs: once however many
  of its patterns cover the agent, in the order each agent wrote them, from
  any node. An event's `source` is its agent, and its `cursor` names that
  agent's log alone; `cursor/2` folds several into one.

      :ok = Wardrik.subscribe(scope, resources: [Wardrik.Resource.parse!("acme/agent/*")])

      receive do
        %Wardrik.Event.RunCompleted{source: agent} -> agent
      end

  The token is checked once, here. A process that subscribes again follows
  those agents as well; `unsubscribe/2` takes patterns away, and a process
  that exits follows none.

  ## Options

  #{NimbleOptions.docs(@subscribe_opts)}
  """
  @doc group: "Events"
  @spec subscribe(Scope.t(), keyword()) :: :ok | {:error, Error.t()}
  def subscribe(%Scope{} = scope, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @subscribe_opts)

    with {:ok, resources} <- readable(scope, opts),
         do: Log.subscribe(resources, Keyword.get(opts, :types, :all), :events)
  end

  @doc """
  Stops sending this process the events of the patterns `:resources`
  names, as it subscribed to them, and goes on with the rest.

  ## Options

  #{NimbleOptions.docs(@resources_opts)}
  """
  @doc group: "Events"
  @spec unsubscribe(Scope.t(), keyword()) :: :ok
  def unsubscribe(%Scope{} = scope, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @resources_opts)
    Log.unsubscribe(Keyword.get_lazy(opts, :resources, fn -> readable_by(scope) end), :events)
  end

  @doc """
  The logs of the agents `:resources` covers as a lazy `Stream` of
  `Wardrik.Event` structs: every one written after the cursor `:after`,
  read page by page, a log at a time, then, with `follow: true`, each as an
  agent writes it, until the process taking it stops. Following, it
  subscribes the process taking it while it runs, so it takes each event
  once, in order, and drops the events sent it as it stops.

      {:ok, message} = Wardrik.agent_ask(scope, agent, "Summarise the inbox")

      {:ok, events} =
        Wardrik.events(scope,
          resources: [Wardrik.AgentAddress.resource(agent)],
          after: message.cursor,
          follow: true
        )

      Enum.find(events, &match?(%Wardrik.Event.RunCompleted{}, &1))

  Wardrik keeps no reader's place. Each event's `cursor` is where the
  stream stands past it, across every log it reads, so a reader keeps the
  last one it handled and reads on from there; or from the cursor of
  `agent_read/2`'s snapshot or `agent_ask/4`'s message. One that starts
  from what is written next, and keeps its place, starts from
  `events_head/2`'s cursor, as `Wardrik.Listener` does. Where a log was
  trimmed past the cursor, the stream takes a
  `Wardrik.Event.EventsDropped` naming the sequence it was after and the
  oldest the log still held, whatever `:types` names, and reads on from
  there.

  ## Options

  #{NimbleOptions.docs(@events_opts)}
  """
  @doc group: "Events"
  @spec events(Scope.t(), keyword()) ::
          {:ok, Enumerable.t(Wardrik.Event.t())} | {:error, Error.t()}
  def events(%Scope{} = scope, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @events_opts)

    with {:ok, resources} <- readable(scope, opts),
         {:ok, positions} <- positions(opts[:after]) do
      {:ok,
       scope.host
       |> Host.store()
       |> Log.stream(resources,
         after: positions,
         follow: opts[:follow],
         types: Keyword.get(opts, :types, :all)
       )
       |> Stream.transform(opts[:after], fn entry, cursor ->
         event = Wardrik.Event.decode(entry, cursor)
         {[event], event.cursor}
       end)}
    end
  end

  defp positions(:head), do: {:ok, :head}

  defp positions(cursor) do
    with :error <- Cursor.decode(cursor),
         do: {:error, Error.new(:invalid, "#{inspect(cursor)} is not a cursor events answered")}
  end

  @doc """
  The cursor at the head of the log of every agent `:resources` covers:
  where each stands now, so `events/2` after it takes what is written from
  now on, and a cursor `cursor/2` moves from it resumes there in all of
  them. An agent whose log is opened after it is read from its start.

      {:ok, head} = Wardrik.events_head(scope, resources: resources)
      {:ok, events} = Wardrik.events(scope, resources: resources, after: head, follow: true)

  ## Options

  #{NimbleOptions.docs(@resources_opts)}
  """
  @doc group: "Events"
  @spec events_head(Scope.t(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def events_head(%Scope{} = scope, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @resources_opts)

    with {:ok, resources} <- readable(scope, opts),
         do: {:ok, Cursor.encode(Log.heads(Host.store(scope.host), resources))}
  end

  @doc """
  `cursor` moved past `event` in its agent's log: the cursor `events/2`
  reads on from after it. It folds the events `subscribe/2` sends into one
  cursor across all their agents. A cursor of `:head` names the logs of the
  events it has been moved past alone, and reads the rest from their start,
  so one that resumes across many agents is moved from `events_head/2`'s.

      cursor = Enum.reduce(events, cursor, &Wardrik.cursor(&2, &1))
  """
  @doc group: "Events"
  @spec cursor(String.t() | :head, Wardrik.Event.t()) :: String.t()
  def cursor(:head, event), do: cursor("", event)

  def cursor(cursor, %{source: log, cursor: past}) when is_binary(past) do
    {:ok, positions} = Cursor.decode(cursor)
    {:ok, %{^log => at}} = Cursor.decode(past)
    Cursor.encode(Map.put(positions, log, at))
  end

  # The patterns `opts` names, or those the scope's token allows
  # `agent.events` on, where it allows it on each whole.
  defp readable(scope, opts) do
    resources = Keyword.get_lazy(opts, :resources, fn -> readable_by(scope) end)
    none = Error.new(:forbidden, "This token reads the events of no agent.")

    Enum.reduce_while(resources, {:error, none}, fn resource, _readable ->
      case authorize(scope, "agent.events", resource) do
        :ok -> {:cont, {:ok, resources}}
        error -> {:halt, error}
      end
    end)
  end

  defp readable_by(%Scope{token: token}), do: Token.resources(token, "agent.events")

  @decided_wait [
    type: :timeout,
    doc:
      "how long, in milliseconds, to wait for the run the decisions carry on, answered as " <>
        "`agent_ask/4` answers with `wait:`. A run left waiting on calls nobody decided " <>
        "answers them as `Wardrik.Waiting`. Needs `agent.events` on the agent."
  ]

  @approve_opts NimbleOptions.new!(
                  note: [type: :string, doc: "what the agent is told with it"],
                  wait: @decided_wait
                )

  @doc """
  Runs the call, or each of the calls, `agent` waits on a person for.
  Acknowledged with the decisions taken, by call id; the agent's log says
  what its turn does next.

  ## Options

  #{NimbleOptions.docs(@approve_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_approve(Scope.t(), AgentAddress.t(), String.t() | [String.t()], keyword()) ::
          decided()
  def agent_approve(%Scope{} = scope, agent, calls, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @approve_opts)
    decision = if(opts[:note], do: {:approve, opts[:note]}, else: :approve)
    decide(scope, agent, calls, decision, opts)
  end

  @deny_opts NimbleOptions.new!(
               reason: [
                 type: :string,
                 default: "A person refused this call.",
                 doc: "why, as the agent is told"
               ],
               wait: @decided_wait
             )

  @doc """
  Refuses the call, or each of the calls, `agent` waits on a person for.
  Acknowledged with the decisions taken, by call id.

  ## Options

  #{NimbleOptions.docs(@deny_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_deny(Scope.t(), AgentAddress.t(), String.t() | [String.t()], keyword()) ::
          decided()
  def agent_deny(%Scope{} = scope, agent, calls, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @deny_opts)
    decide(scope, agent, calls, {:deny, opts[:reason]}, opts)
  end

  defp decide(scope, agent, calls, decision, opts) do
    decisions = Map.new(List.wrap(calls), &{&1, decision})
    agent_decide(scope, agent, decisions, Keyword.take(opts, [:wait]))
  end

  @decide_opts NimbleOptions.new!(wait: @decided_wait)

  @doc """
  Decides several of the calls `agent` waits on at once, each by its id:
  `:approve`, `{:approve, note}` or `{:deny, reason}`, as `agent_approve/4`
  and `agent_deny/4` decide one kind. Acknowledged with the decisions taken;
  calls left out stay waiting.

  A scope that may read the agent may ask; the agent takes the decisions
  from one whose token allows `agent.decide` on it, or whose principal asked
  for the turn that waits and acts directly, as `Wardrik.Agent.decide/3`
  says, and answers anyone else `:forbidden`.

  ## Options

  #{NimbleOptions.docs(@decide_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_decide(Scope.t(), AgentAddress.t(), %{String.t() => decision()}, keyword()) ::
          decided()
  def agent_decide(%Scope{} = scope, agent, decisions, opts \\ []) when is_map(decisions) do
    opts = NimbleOptions.validate!(opts, @decide_opts)
    scope = refreshed(scope)

    with :ok <- authorize(scope, "agent.read", agent) do
      case opts[:wait] do
        nil -> decided(scope, agent, decisions)
        ms -> decided_then(scope, agent, decisions, ms)
      end
    end
  end

  defp decided(scope, agent, decisions) do
    case Agent.decide(agent, decisions, token: scope.token, host: scope.host) do
      :ok -> {:ok, decisions}
      {:error, reason} -> {:error, undecided(reason, agent, decisions)}
    end
  end

  # The run the decisions carry on is the one waiting, which the snapshot
  # names before they are taken.
  defp decided_then(scope, agent, decisions, ms) do
    with :ok <- authorize(scope, "agent.events", agent),
         {:ok, %Snapshot{trace_id: run, cursor: cursor}} <- agent_snapshot(agent, scope.host),
         {:ok, _decisions} <- decided(scope, agent, decisions),
         do: Wait.answer(Host.store(scope.host), agent, cursor, {:resumed, run}, ms)
  end

  defp undecided(:not_found, agent, _decisions), do: Error.no_agent(agent)

  defp undecided(:not_parked, agent, _decisions),
    do: Error.new(:conflict, "#{agent} is not waiting on anything.")

  defp undecided(:stale_decision, agent, decisions),
    do: Error.new(:conflict, "#{agent} is not waiting on #{named(decisions)}.")

  defp undecided(:forbidden, agent, _decisions) do
    Error.new(
      :forbidden,
      "This token does not allow agent.decide on #{agent}, nor asked for the turn that waits."
    )
  end

  defp undecided(:unrecorded, agent, _decisions),
    do: Error.new(:unavailable, "#{agent} could not record the decision, so it was not taken.")

  defp named(decisions) do
    case decisions |> Map.keys() |> Enum.sort() do
      [only] -> only
      ids -> "#{Enum.join(Enum.drop(ids, -1), ", ")} and #{List.last(ids)}"
    end
  end

  @doc """
  Where a person authorizes the call `call` that `agent` waits on: the page,
  and the code to enter where one is needed. The link is kept out of every
  event, so only a scope that may decide the call reads it.
  """
  @doc group: "Talking to an agent"
  @spec agent_authorization_read(Scope.t(), AgentAddress.t(), String.t()) ::
          {:ok, Wardrik.Call.Ask.link()} | {:error, Error.t()}
  def agent_authorization_read(%Scope{} = scope, agent, call) do
    with :ok <- authorize(scope, "agent.authorization.read", agent),
         {:ok, calls} <- parked(agent, scope.host),
         do: authorization(Enum.find(calls, &(elem(&1, 0).id == call)), agent, call)
  end

  defp authorization({%{link: %{url: _url} = link}, _prompt}, _agent, _call), do: {:ok, link}

  defp authorization({_waiting, _prompt}, _agent, call),
    do: {:error, Error.new(:not_found, "#{call} waits on no authorization.")}

  defp authorization(nil, agent, call),
    do: {:error, Error.new(:not_found, "#{agent} is not waiting on #{call}.")}

  defp parked(agent, host) do
    case Agent.parked(agent, host: host) do
      {:error, :not_found} -> {:error, Error.no_agent(agent)}
      calls -> {:ok, calls}
    end
  end

  @doc "`agent`'s snapshot: what it is doing, what it waits on, and its conversation."
  @doc group: "Talking to an agent"
  @spec agent_read(Scope.t(), AgentAddress.t()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def agent_read(%Scope{} = scope, agent) do
    with :ok <- authorize(scope, "agent.read", agent), do: agent_snapshot(agent, scope.host)
  end

  defp agent_snapshot(agent, host) do
    case Agent.snapshot(agent, host: host) do
      {:error, :not_found} -> {:error, Error.no_agent(agent)}
      snapshot -> {:ok, snapshot}
    end
  end

  @doc """
  Empties `agent`'s conversation, and the labels of what it read, and
  answers its snapshot. Its files, triggers and config stay. Refused while
  it runs a turn or waits on a person.
  """
  @doc group: "Talking to an agent"
  @spec agent_clear(Scope.t(), AgentAddress.t()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def agent_clear(%Scope{} = scope, agent) do
    with :ok <- authorize(scope, "agent.clear", agent),
         :ok <- cleared(Agent.clear(agent, host: scope.host), agent) do
      audit(scope, [{:agent_cleared, agent}])
      agent_read(scope, agent)
    end
  end

  defp cleared(:ok, _agent), do: :ok
  defp cleared({:error, :not_found}, agent), do: {:error, Error.no_agent(agent)}

  defp cleared({:error, :busy}, agent) do
    {:error,
     Error.new(
       :conflict,
       "#{agent} is running a turn, or waiting on a person; cancel it, or wait"
     )}
  end

  @doc """
  Every agent the `Wardrik.Resource` pattern covers, as `acme/agent/*`,
  awake or asleep, as the fleet lists each, sorted by ID.
  """
  @doc group: "Talking to an agent"
  @spec agents_list(Scope.t(), Resource.t()) :: {:ok, [Member.t()]} | {:error, Error.t()}
  def agents_list(%Scope{} = scope, pattern) do
    with :ok <- authorize(scope, "agents.list", pattern),
         do: {:ok, Fleet.list(pattern, host: scope.host)}
  end

  @doc """
  Every call an agent `pattern` covers waits on a person for, with the
  agent it is for, as `{id, {call, prompt}}`.
  """
  @doc group: "Talking to an agent"
  @spec agents_parked(Scope.t(), Resource.t()) ::
          {:ok, [{AgentAddress.t(), {Wardrik.Tool.call(), String.t()}}]} | {:error, Error.t()}
  def agents_parked(%Scope{} = scope, pattern) do
    with :ok <- authorize(scope, "agents.parked", pattern) do
      {:ok,
       for(
         %Member{status: :parked, id: id} <- Fleet.list(pattern, host: scope.host),
         {:ok, calls} <- [parked(id, scope.host)],
         waiting <- calls,
         do: {id, waiting}
       )}
    end
  end

  # -- agent lifecycle ----------------------------------------------------------

  @define_opts NimbleOptions.new!(
                 held: [
                   type: {:list, {:struct, Wardrik.Hook}},
                   default: [],
                   doc:
                     "hooks it is held to as well, ahead of its own: those of an agent that " <>
                       "defines a worker, say; they only narrow what it may do"
                 ]
               )

  @doc """
  Defines `agent` with `definition`, or defines it again, and answers its
  snapshot. It runs under the `:held` hooks, then the policy the token
  names, ahead of its own; the host's definitions keep both with it, and
  find that policy by its name each time it starts.

  A thread runs on its agent's definition, so this refuses a
  `Wardrik.Thread`, naming the agent to define instead.

  ## Options

  #{NimbleOptions.docs(@define_opts)}
  """
  @doc group: "Agent lifecycle"
  @spec agent_define(Scope.t(), AgentAddress.t(), map(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Error.t()}
  def agent_define(%Scope{} = scope, agent, definition, opts \\ [])
      when is_map(definition) do
    opts = NimbleOptions.validate!(opts, @define_opts)
    scope = refreshed(scope)

    with :ok <- authorize(scope, "agent.define", agent),
         {:ok, spec} <-
           defined(scope, agent, definition, source: {:api, scope.token}, held: opts[:held]),
         {:ok, _pid} <- started(Fleet.put(spec), agent) do
      audit(scope, [{:agent_defined, agent}])
      agent_snapshot(agent, scope.host)
    end
  end

  # Reads `fields` as `agent`'s definition under its owner's context, and
  # keeps it once the spec it writes builds.
  defp defined(scope, agent, fields, opts) do
    definitions = Host.definitions(scope.host)
    context = Definitions.context(definitions, agent)

    with {:ok, definition} <-
           refused(Definition.read(fields, [id: agent, context: context] ++ opts)),
         {:ok, spec} <-
           refused(Definition.spec(definition, context: context, host: scope.host)),
         :ok <- refused(Definitions.put(definitions, definition)),
         do: {:ok, spec}
  end

  # A refusal of the host's definitions, as an error of its kind.
  defp refused({:error, :conflict, message}), do: {:error, Error.new(:conflict, message)}
  defp refused({:error, message}), do: {:error, Error.new(:invalid, message)}
  defp refused(ok), do: ok

  @doc """
  `agent`'s definition as it was last put, and the tools it names that
  offer nothing yet. Refuses a `Wardrik.Thread`, naming its agent: a thread
  has no definition of its own.
  """
  @doc group: "Agent lifecycle"
  @spec agent_definition_read(Scope.t(), AgentAddress.t()) ::
          {:ok, %{definition: Definition.t(), missing: [String.t()]}} | {:error, Error.t()}
  def agent_definition_read(%Scope{} = scope, agent) do
    definitions = Host.definitions(scope.host)

    with :ok <- authorize(scope, "agent.definition.read", agent) do
      case Definitions.get(definitions, agent) do
        {:ok, definition} ->
          {:ok,
           %{
             definition: definition,
             missing: Definition.missing(definition, host: scope.host)
           }}

        {:error, :not_found} ->
          {:error, undefined(agent)}
      end
    end
  end

  defp undefined(agent), do: Error.new(:not_found, "#{agent} has no definition kept.")

  @spawn_opts NimbleOptions.new!(
                node: [
                  type: :atom,
                  doc:
                    "the node it starts on, which only a token allowing it on the deployment may choose"
                ]
              )

  @doc """
  Starts `agent`, and answers it as the fleet lists it, with what it started
  from: one running already runs on, one asleep wakes, one the host defines
  starts on its definition, and one nothing defines yet is defined from the
  `defaults` of its owner's context, which is kept for it. A
  `Wardrik.Thread` starts on its agent's definition, and one whose agent
  nothing defines is refused: define the agent first.

  ## Options

  #{NimbleOptions.docs(@spawn_opts)}
  """
  @doc group: "Agent lifecycle"
  @spec agent_spawn(Scope.t(), AgentAddress.t(), keyword()) ::
          {:ok, Spawned.t()} | {:error, Error.t()}
  def agent_spawn(%Scope{} = scope, agent, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @spawn_opts)

    with :ok <- spawning(scope, agent, opts[:node]),
         {from, spec} = from(scope, agent),
         {:ok, actions} <- spawn(scope, agent, {from, spec}, opts[:node]) do
      audit(scope, actions)
      {:ok, %Spawned{member: Fleet.lookup(agent, host: scope.host), from: from}}
    end
  end

  # Where an agent starts is the deployment's to say, so only a token
  # allowing it on the deployment names a node.
  defp spawning(scope, agent, nil), do: authorize(scope, "agent.spawn", agent)

  defp spawning(scope, _agent, node) do
    with :ok <- on_deployment(scope, "agent.spawn"), do: deployed(node)
  end

  defp deployed(node) do
    if node in Fleet.nodes(),
      do: :ok,
      else: {:error, Error.new(:invalid, "#{node} is not a node of this deployment.")}
  end

  defp from(scope, agent) do
    definitions = Host.definitions(scope.host)

    case {Fleet.lookup(agent, host: scope.host),
          Definitions.spec(definitions, AgentAddress.agent(agent), host: scope.host)} do
      {%Member{asleep: false}, _spec} -> {:running, nil}
      {_member, {:ok, spec}} -> {:definition, %{spec | id: agent}}
      {%Member{asleep: true}, _none} -> {:store, nil}
      {nil, _none} -> {:new, nil}
    end
  end

  # Starts the agent as it was found, on `node`, or wherever the fleet puts
  # it where `nil`: what the audit records of it.
  defp spawn(_scope, _agent, {:running, nil}, _node), do: {:ok, []}

  defp spawn(_scope, agent, {:store, nil}, node),
    do: agent |> Fleet.spawn(if(node, do: [node: node], else: [])) |> spawned(agent)

  defp spawn(_scope, agent, {:definition, spec}, node), do: spec |> put(node) |> spawned(agent)

  defp spawn(scope, %AgentID{} = agent, {:new, nil}, node) do
    defaults = Definitions.context(Host.definitions(scope.host), agent).defaults

    with {:ok, spec} <- defined(scope, agent, defaults, source: :defaults),
         do: spec |> put(node) |> spawned(agent)
  end

  defp spawn(_scope, thread, {:new, nil}, _node),
    do: {:error, undefined(AgentAddress.agent(thread))}

  # An agent bound for a node is started there first, then given its spec.
  defp put(spec, nil), do: Fleet.put(spec)

  defp put(spec, node) do
    with {:ok, _pid} <- Fleet.spawn(spec.id, Wardrik.Agent.Spec.options(spec) ++ [node: node]),
         do: Fleet.put(spec)
  end

  defp spawned({:ok, pid}, agent), do: {:ok, [{:agent_spawned, agent, node(pid)}]}

  defp spawned({:error, reason}, agent),
    do: {:error, Error.new(:unavailable, "#{agent} did not start: #{inspect(reason)}")}

  defp started({:ok, pid}, _agent), do: {:ok, pid}

  defp started({:error, reason}, agent) do
    Logger.warning("#{agent} did not start: #{inspect(reason)}")
    {:error, Error.new(:unavailable, "#{agent} did not start.")}
  end

  @doc """
  Starts `agent` again on `node`, with what it had, and answers it as the
  fleet lists it. What it is doing is interrupted. Only a token allowing
  `agent.move` on `deployment/*` may move one, since where an agent runs is
  the deployment's to say.
  """
  @doc group: "Agent lifecycle"
  @spec agent_move(Scope.t(), AgentAddress.t(), node()) :: {:ok, Member.t()} | {:error, Error.t()}
  def agent_move(%Scope{} = scope, agent, node) when is_atom(node) do
    with {:ok, moving} <- moving(scope, agent, node),
         {:ok, actions} <- moved(moving) do
      audit(scope, actions)
      member(agent, scope.host)
    end
  end

  @doc """
  What `agent_move/3` would do, checked as it checks: where the agent runs,
  where it goes, and what it is doing, which a move interrupts.
  """
  @doc group: "Agent lifecycle"
  @spec agent_move_preview(Scope.t(), AgentAddress.t(), node()) ::
          {:ok, Moving.t()} | {:error, Error.t()}
  def agent_move_preview(%Scope{} = scope, agent, node) when is_atom(node) do
    moving(scope, agent, node)
  end

  defp moving(scope, agent, node) do
    with :ok <- on_deployment(scope, "agent.move"),
         :ok <- deployed(node),
         {:ok, member} <- member(agent, scope.host) do
      from = if member.asleep, do: :asleep, else: member.node
      {:ok, %Moving{agent: agent, from: from, to: node, status: member.status}}
    end
  end

  defp moved(%Moving{from: to, to: to}), do: {:ok, []}

  defp moved(%Moving{agent: agent, to: to}) do
    case Fleet.move(agent, to) do
      {:ok, _pid} ->
        {:ok, [{:agent_moved, agent, to}]}

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{agent} did not move to #{to}: #{inspect(reason)}")}
    end
  end

  defp member(agent, host) do
    case Fleet.lookup(agent, host: host) do
      nil -> {:error, Error.no_agent(agent)}
      member -> {:ok, member}
    end
  end

  @doc """
  Ends the turn `agent` is taking, or the calls it waits on a person for,
  and what is queued behind it. It keeps running; one taking no turn is
  left as it is.
  """
  @doc group: "Agent lifecycle"
  @spec agent_cancel(Scope.t(), AgentAddress.t()) :: :ok | {:error, Error.t()}
  def agent_cancel(%Scope{} = scope, agent) do
    with :ok <- authorize(scope, "agent.cancel", agent),
         {:ok, member} <- member(agent, scope.host),
         do: audit(scope, for(id <- cancelled([member]), do: {:agent_cancelled, id}))
  end

  @doc "Ends the turn of every agent `pattern` covers, and answers those it ended."
  @doc group: "Agent lifecycle"
  @spec agents_cancel(Scope.t(), Resource.t()) :: {:ok, [AgentAddress.t()]} | {:error, Error.t()}
  def agents_cancel(%Scope{} = scope, pattern) do
    with :ok <- authorize(scope, "agents.cancel", pattern) do
      cancelled = cancelled(Fleet.list(pattern, host: scope.host))
      audit(scope, for(id <- cancelled, do: {:agent_cancelled, id, pattern}))
      {:ok, cancelled}
    end
  end

  # Interrupts each of `members` taking a turn, or waiting on a person, and
  # answers those it interrupted.
  defp cancelled(members) do
    for %Member{id: id, status: status} <- members,
        status != :idle,
        Agent.interrupt(id) == :ok,
        do: id
  end

  @doc """
  Stops `agent` now, keeping its conversation, and answers it as the fleet
  lists it, asleep: it wakes when something asks it. One asleep already is
  left as it is.
  """
  @doc group: "Agent lifecycle"
  @spec agent_stop(Scope.t(), AgentAddress.t()) :: {:ok, Member.t()} | {:error, Error.t()}
  def agent_stop(%Scope{} = scope, agent) do
    with :ok <- authorize(scope, "agent.stop", agent),
         {:ok, member} <- member(agent, scope.host) do
      :ok = stopped(scope, member)
      member(agent, scope.host)
    end
  end

  # One asleep already has nothing to stop, and nothing is recorded; nor for
  # one that went to sleep since it was looked up.
  defp stopped(_scope, %Member{asleep: true}), do: :ok

  defp stopped(scope, %Member{id: agent}) do
    case Fleet.stop(agent) do
      :ok -> audit(scope, [{:agent_stopped, agent}])
      {:error, :noproc} -> :ok
    end
  end

  @doc """
  Removes `agent`, with everything it had, and the definition the host
  keeps of it, which may refuse. It is forgotten where it is kept, awake or
  asleep, or a definition of it is.
  """
  @doc group: "Agent lifecycle"
  @spec agent_forget(Scope.t(), AgentAddress.t()) :: :ok | {:error, Error.t()}
  def agent_forget(%Scope{} = scope, agent) do
    with {:ok, _forgetting} <- forgetting(scope, agent) do
      kept = Definitions.delete(Host.definitions(scope.host), agent) == :ok
      forgotten(scope, agent, kept)
    end
  end

  defp forgotten(scope, agent, kept) do
    stored = Fleet.stored?(agent)
    if stored, do: :ok = Fleet.forget(agent)

    if stored or kept,
      do: audit(scope, [{:agent_forgotten, agent}]),
      else: {:error, Error.no_agent(agent)}
  end

  @doc "What `agent_forget/2` would do, checked as it checks."
  @doc group: "Agent lifecycle"
  @spec agent_forget_preview(Scope.t(), AgentAddress.t()) ::
          {:ok, Forgetting.t()} | {:error, Error.t()}
  def agent_forget_preview(%Scope{} = scope, agent) do
    forgetting(scope, agent)
  end

  defp forgetting(scope, agent) do
    with :ok <- authorize(scope, "agent.forget", agent),
         :ok <- kept(scope.host, agent),
         :ok <- refused(Definitions.editable(Host.definitions(scope.host), agent)),
         do: {:ok, %Forgetting{agents: [agent], kept: []}}
  end

  defp kept(host, agent) do
    if Fleet.stored?(agent) or
         match?({:ok, _kept}, Definitions.get(Host.definitions(host), agent)),
       do: :ok,
       else: {:error, Error.no_agent(agent)}
  end

  @doc """
  Removes every agent `pattern` covers but those the host keeps, and
  answers what became of each. A pattern covering none is not found, and
  one whose every agent is kept is a conflict saying why.
  """
  @doc group: "Agent lifecycle"
  @spec agents_forget(Scope.t(), Resource.t()) ::
          {:ok, %{AgentAddress.t() => outcome()}} | {:error, Error.t()}
  def agents_forget(%Scope{} = scope, pattern) do
    with {:ok, %Forgetting{agents: agents, kept: kept}} <- forgetting_under(scope, pattern) do
      outcomes = Map.new(agents, &{&1, forget(scope.host, &1)})
      audit(scope, for({id, :forgotten} <- outcomes, do: {:agent_forgotten, id, pattern}))
      {:ok, Map.merge(outcomes, Map.new(kept, fn {id, why} -> {id, {:kept, why}} end))}
    end
  end

  defp forget(host, agent) do
    definitions = Host.definitions(host)

    with :ok <- Definitions.editable(definitions, agent),
         _kept = Definitions.delete(definitions, agent),
         :ok <- Fleet.forget(agent) do
      :forgotten
    else
      {:error, :conflict, why} -> {:kept, why}
      {:error, reason} -> {:failed, inspect(reason)}
    end
  end

  @doc "What `agents_forget/2` would do, checked as it checks."
  @doc group: "Agent lifecycle"
  @spec agents_forget_preview(Scope.t(), Resource.t()) ::
          {:ok, Forgetting.t()} | {:error, Error.t()}
  def agents_forget_preview(%Scope{} = scope, pattern) do
    forgetting_under(scope, pattern)
  end

  defp forgetting_under(scope, pattern) do
    with :ok <- authorize(scope, "agents.forget", pattern) do
      definitions = Host.definitions(scope.host)

      checked =
        for %Member{id: id} <- Fleet.list(pattern, host: scope.host),
            do: {id, Definitions.editable(definitions, id)}

      case {for({id, :ok} <- checked, do: id),
            for({id, {:error, :conflict, why}} <- checked, do: {id, why})} do
        {[], []} -> {:error, Error.new(:not_found, "No agent #{pattern} covers runs.")}
        {[], kept} -> {:error, Error.new(:conflict, Enum.map_join(kept, "\n", &elem(&1, 1)))}
        {agents, kept} -> {:ok, %Forgetting{agents: agents, kept: kept}}
      end
    end
  end

  @doc """
  The tool calls `agent` is running now, each with its id, the tool's name,
  and how long it has run. An agent asleep runs none, and is not found.
  """
  @doc group: "Agent lifecycle"
  @spec agent_calls(Scope.t(), AgentAddress.t()) ::
          {:ok, [%{call_id: String.t(), name: String.t(), elapsed_ms: non_neg_integer()}]}
          | {:error, Error.t()}
  def agent_calls(%Scope{} = scope, agent) do
    with :ok <- authorize(scope, "agent.calls", agent),
         {:ok, node} <- awake(agent) do
      calls = :erpc.call(node, ToolRunner, :in_flight, [agent])
      {:ok, Enum.map(calls, &Map.take(&1, [:call_id, :name, :elapsed_ms]))}
    end
  end

  @doc """
  Stops the tool call `call_id` that `agent` is running: the model is
  answered with an error, and the rest of the turn goes on. A call the agent
  is not running, or an agent asleep, is not found.
  """
  @doc group: "Agent lifecycle"
  @spec agent_call_kill(Scope.t(), AgentAddress.t(), String.t()) :: :ok | {:error, Error.t()}
  def agent_call_kill(%Scope{} = scope, agent, call_id)
      when is_binary(call_id) do
    with :ok <- authorize(scope, "agent.call.kill", agent),
         {:ok, node} <- awake(agent) do
      case :erpc.call(node, ToolRunner, :kill_call, [agent, call_id]) do
        :ok ->
          audit(scope, [{:call_killed, agent, call_id}])

        {:error, :not_found} ->
          {:error, Error.new(:not_found, "#{agent} is not running #{call_id}.")}
      end
    end
  end

  # The node `agent` runs on, whose tool runner holds its calls.
  defp awake(agent) do
    case Fleet.held_pid(agent, wake: false) do
      nil -> {:error, Error.no_agent(agent)}
      pid -> {:ok, node(pid)}
    end
  end

  # -- triggers -------------------------------------------------------------------

  @doc """
  Sets `agent`'s trigger `name` to `fields`, as `WardrikProtocol`'s
  `trigger_definition.json` describes one, and answers the trigger. A
  trigger is part of the agent's definition, so the host's definitions set
  it, and a `Wardrik.Thread` is refused, naming its agent.
  """
  @doc group: "Triggers"
  @spec agent_trigger_set(Scope.t(), AgentAddress.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def agent_trigger_set(%Scope{} = scope, agent, name, fields)
      when is_binary(name) and is_map(fields) do
    with :ok <- authorize(scope, "agent.trigger.set", agent),
         {:ok, trigger} <- trigger_set(scope, agent, name, fields),
         do: audited(scope, [{:trigger_set, agent, name}], trigger)
  end

  defp trigger_set(scope, agent, name, fields) do
    case Definitions.put_trigger(Host.definitions(scope.host), agent, name, fields) do
      {:ok, _created_or_changed, trigger} -> {:ok, trigger}
      {:error, :not_found} -> {:error, undefined(agent)}
      refused -> refused(refused)
    end
  end

  @doc """
  Removes `agent`'s trigger `name`, and answers it as `agent_trigger_set/4`
  would. Refuses a `Wardrik.Thread`, naming its agent.
  """
  @doc group: "Triggers"
  @spec agent_trigger_remove(Scope.t(), AgentAddress.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def agent_trigger_remove(%Scope{} = scope, agent, name) when is_binary(name) do
    with :ok <- authorize(scope, "agent.trigger.remove", agent),
         {:ok, trigger} <- trigger_removed(scope, agent, name),
         do: audited(scope, [{:trigger_removed, agent, name}], trigger)
  end

  defp trigger_removed(scope, agent, name) do
    case Definitions.delete_trigger(Host.definitions(scope.host), agent, name) do
      {:ok, trigger} -> {:ok, trigger}
      {:error, :not_found} -> {:error, Error.new(:not_found, "#{agent} has no trigger #{name}.")}
      refused -> refused(refused)
    end
  end

  @doc """
  Hands `agent`'s trigger `trigger` a request from outside, its `:headers`
  and `:body`, which the trigger checks. Acknowledged with `:asked`, or
  `:seen` where it was handed the same request before.

  The scope's token must allow `agent.trigger.deliver` on the agent, so a
  surface that takes such requests from anyone makes a token allowing just
  that, on just that agent; the trigger decides whether the request is the
  sender's. One that is not is
  answered as one to no such trigger, so a request tells its sender nothing
  of the triggers another org's agents have.
  """
  @doc group: "Triggers"
  @spec agent_trigger_deliver(Scope.t(), AgentID.t(), String.t(), %{
          headers: [{String.t(), String.t()}],
          body: binary()
        }) :: {:ok, atom()} | {:error, Error.t()}
  def agent_trigger_deliver(
        %Scope{} = scope,
        %AgentID{} = agent,
        trigger,
        %{headers: headers, body: body}
      ) do
    with :ok <- authorize(scope, "agent.trigger.deliver", agent) do
      request = %{headers: headers, body: body}

      case Wardrik.Triggers.deliver(Host.triggers(scope.host), agent, trigger, request: request) do
        {:ok, status} ->
          {:ok, status}

        {:error, :not_found} ->
          {:error, no_trigger(agent, trigger)}

        {:error, :forbidden, _message} ->
          {:error, no_trigger(agent, trigger)}

        {:error, :unavailable, message} ->
          {:error, Error.new(:unavailable, message)}

        :unsupported ->
          {:error, Error.new(:unsupported, "This server takes no requests for triggers.")}
      end
    end
  end

  defp no_trigger(agent, trigger),
    do: Error.new(:not_found, "#{agent} has no trigger #{trigger} to deliver to.")

  # -- servers and connections ------------------------------------------------------

  @doc """
  The MCP servers `owner` added, a person or an org, as the namespace
  `Wardrik.Resource` names.
  """
  @doc group: "Servers and connections"
  @spec servers_list(Scope.t(), Resource.t()) :: {:ok, [Server.t()]} | {:error, Error.t()}
  def servers_list(%Scope{} = scope, owner) do
    with :ok <- authorize(scope, "servers.list", owned(owner, :server)),
         do: servers(scope, owner)
  end

  defp servers(scope, owner) do
    case Servers.list(Host.servers(scope.host), owner) do
      :unsupported -> {:error, Wardrik.Servers.None.unsupported()}
      servers -> {:ok, servers}
    end
  end

  @doc """
  Adds `server` for `owner`'s agents, by its name, URL, how they sign in to
  it and which of its tools they take, and answers it, with where someone
  signs in to it first where they have to.
  """
  @doc group: "Servers and connections"
  @spec servers_add(Scope.t(), Resource.t(), Server.t()) ::
          {:ok, Server.t()} | {:error, Error.t()}
  def servers_add(%Scope{} = scope, owner, %Server{} = server) do
    with :ok <- authorize(scope, "servers.add", owned(owner, :server)) do
      case Servers.add(Host.servers(scope.host), owner,
             name: server.name,
             fields: fields(server),
             by: scope.token.principal
           ) do
        {:ok, added} ->
          key = Resource.new(owner, server: server.name)

          audited(scope, [{:server_added, key, server.url}], %{
            server
            | authorization: if(added == :connected, do: nil, else: added)
          })

        {:error, %Error{} = error} ->
          {:error, error}

        :unsupported ->
          {:error, Wardrik.Servers.None.unsupported()}
      end
    end
  end

  # The fields `server` is added with, as `WardrikProtocol`'s
  # `input_servers_add.json` describes them.
  defp fields(server) do
    how =
      case server.auth do
        "secret" -> given(name: server.secret, header: server.header, scheme: server.scheme)
        "oauth" -> given(scopes: server.scopes)
        _none -> %{}
      end

    Map.merge(
      %{"url" => server.url, "auth" => %{server.auth => how}},
      given(only: server.only, except: server.except)
    )
  end

  # The fields of `pairs` that are given, by their names as text.
  defp given(pairs),
    do: for({key, value} <- pairs, value != nil, into: %{}, do: {"#{key}", value})

  @doc """
  Removes the MCP server `name` `owner` added, and answers it as it was:
  its agents lose its tools on their next turn.
  """
  @doc group: "Servers and connections"
  @spec servers_remove(Scope.t(), Resource.t(), String.t()) ::
          {:ok, Server.t()} | {:error, Error.t()}
  def servers_remove(%Scope{} = scope, owner, name) when is_binary(name) do
    with :ok <- authorize(scope, "servers.remove", owned(owner, :server)),
         {:ok, servers} <- servers(scope, owner),
         :ok <-
           Servers.remove(Host.servers(scope.host), owner, name: name, by: scope.token.principal) do
      audited(
        scope,
        [{:server_removed, Resource.new(owner, server: name)}],
        Enum.find(servers, &(&1.name == name))
      )
    end
  end

  @doc "The accounts the deployment offers `owner`, and who holds each; never a value."
  @doc group: "Servers and connections"
  @spec connections_list(Scope.t(), Resource.t()) ::
          {:ok, [Connection.t()]} | {:error, Error.t()}
  def connections_list(%Scope{} = scope, owner) do
    with :ok <- authorize(scope, "connections.list", owned(owner, :secret)),
         do: connections(scope, owner)
  end

  defp connections(scope, owner) do
    case Connections.list(Host.connections(scope.host), owner) do
      :unsupported -> {:error, Wardrik.Connections.None.unsupported()}
      connections -> {:ok, connections}
    end
  end

  @doc """
  Connects `owner`'s account at `provider` before any agent asks for it, and
  answers the connection, with where to authorize it where it is not held.
  Nothing parks on it.
  """
  @doc group: "Servers and connections"
  @spec connections_connect(Scope.t(), Resource.t(), String.t()) ::
          {:ok, Connection.t()} | {:error, Error.t()}
  def connections_connect(%Scope{} = scope, owner, provider)
      when is_binary(provider) do
    with :ok <- authorize(scope, "connections.connect", owned(owner, :secret)),
         {:ok, link} <- connect(scope, owner, provider),
         {:ok, connections} <- connections(scope, owner) do
      {:ok, %{Enum.find(connections, &(&1.provider == provider)) | authorization: link}}
    end
  end

  defp connect(scope, owner, provider) do
    connections = Host.connections(scope.host)

    case Connections.connect(connections, provider, owner, by: scope.token.principal) do
      {:ok, :held} ->
        {:ok, nil}

      {:ok, link} ->
        {:ok, link}

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "No account named #{provider} is offered.")}

      {:error, _reason} ->
        {:error, Error.new(:unavailable, "#{provider} could not start a sign-in now.")}

      :unsupported ->
        {:error, Wardrik.Connections.None.unsupported()}
    end
  end

  @doc """
  Forgets `owner`'s account at `provider`, so the next call that needs it
  asks them to connect again, and answers the connection as it was.
  """
  @doc group: "Servers and connections"
  @spec connections_disconnect(Scope.t(), Resource.t(), String.t()) ::
          {:ok, Connection.t()} | {:error, Error.t()}
  def connections_disconnect(%Scope{} = scope, owner, provider)
      when is_binary(provider) do
    with :ok <- authorize(scope, "connections.disconnect", owned(owner, :secret)) do
      case Connections.disconnect(Host.connections(scope.host), provider, owner) do
        :ok ->
          audited(scope, [{:secret_removed, provider, owner}], %Connection{
            provider: provider,
            connected: true
          })

        {:error, :not_found} ->
          {:error, Error.new(:not_found, "#{owner} holds no #{provider}.")}

        {:error, _reason} ->
          {:error, Error.new(:unavailable, "#{provider} could not be forgotten now.")}

        :unsupported ->
          {:error, Wardrik.Connections.None.unsupported()}
      end
    end
  end

  # Every one of `owner`'s resources of `type`, as `acme/server/*`: an owner's
  # servers, and their accounts, are checked as one.
  defp owned(owner, type), do: Resource.parse!("#{owner}/#{type}/*")

  # -- tokens -----------------------------------------------------------------------

  @doc "Every token the host keeps, oldest first; never a secret."
  @doc group: "Tokens"
  @spec tokens_list(Scope.t()) :: {:ok, [Tokens.Entry.t()]} | {:error, Error.t()}
  def tokens_list(%Scope{} = scope) do
    with :ok <- on_deployment(scope, "tokens.list"), do: tokens(scope)
  end

  defp tokens(scope) do
    case Tokens.list(Host.tokens(scope.host)) do
      :unsupported -> {:error, Wardrik.Tokens.None.unsupported()}
      tokens -> {:ok, tokens}
    end
  end

  @create_token_opts NimbleOptions.new!(
                       policy: [
                         type: :string,
                         doc:
                           "the name of the policy every agent it defines runs under; " <>
                             "the scope's own where left out"
                       ],
                       expires_in: [
                         type: :pos_integer,
                         doc: "how many seconds it works for; the host's `api:` expiry by default"
                       ]
                     )

  @doc """
  Makes a token named `name`, allowing what `statements` state, and answers
  it with its secret, given this once; the audit records the token, never
  the secret. It acts for the scope's principal, who made it, and every
  agent it defines runs under the policy `:policy` names, or the one the
  scope's token names: a policy only ever narrows what an agent's own
  allows.

  ## Options

  #{NimbleOptions.docs(@create_token_opts)}
  """
  @doc group: "Tokens"
  @spec tokens_create(Scope.t(), String.t(), [Statement.t()], keyword()) ::
          {:ok, Tokens.Entry.t()} | {:error, Error.t()}
  def tokens_create(%Scope{} = scope, name, statements, opts \\ [])
      when is_binary(name) and is_list(statements) do
    opts = NimbleOptions.validate!(opts, @create_token_opts)
    seconds = Keyword.get_lazy(opts, :expires_in, fn -> Host.expires(scope.host, :api) end)

    token = %Token{
      principal: scope.token.principal,
      scope: statements,
      policy: Keyword.get(opts, :policy, scope.token.policy),
      expires: from_now(seconds)
    }

    with :ok <- on_deployment(scope, "tokens.create") do
      case Tokens.create(Host.tokens(scope.host), name, token: token) do
        {:ok, entry} -> audited(scope, [{:token_created, entry.id, entry.name, token}], entry)
        {:error, message} -> {:error, Error.new(:invalid, message)}
        :unsupported -> {:error, Wardrik.Tokens.None.unsupported()}
      end
    end
  end

  @doc """
  Stops the token `id` working, ends what is open on it, and answers it,
  without its secret.
  """
  @doc group: "Tokens"
  @spec tokens_revoke(Scope.t(), String.t()) :: {:ok, Tokens.Entry.t()} | {:error, Error.t()}
  def tokens_revoke(%Scope{} = scope, id) when is_binary(id) do
    with :ok <- on_deployment(scope, "tokens.revoke"),
         {:ok, tokens} <- tokens(scope),
         {:ok, entry} <- token(tokens, id) do
      case Tokens.revoke(Host.tokens(scope.host), id) do
        :ok -> audited(scope, [{:token_revoked, id}], entry)
        {:error, :not_found} -> token([], id)
      end
    end
  end

  defp token(tokens, id) do
    case Enum.find(tokens, &(&1.id == id)) do
      nil -> {:error, Error.new(:not_found, "No token has the id #{id}.")}
      entry -> {:ok, entry}
    end
  end

  # -- the deployment ---------------------------------------------------------------

  @doc "The deployment's nodes, each with how many agents run on it, and how many sleep."
  @doc group: "Deployment"
  @spec deployment_nodes(Scope.t()) :: {:ok, Nodes.t()} | {:error, Error.t()}
  def deployment_nodes(%Scope{} = scope) do
    with :ok <- on_deployment(scope, "deployment.nodes") do
      {asleep, running} =
        Enum.split_with(Fleet.list(Resource.parse!("*"), host: scope.host), & &1.asleep)

      counts = Enum.frequencies_by(running, & &1.node)
      nodes = for node <- Fleet.nodes(), do: {node, Map.get(counts, node, 0)}
      {:ok, %Nodes{nodes: nodes, asleep: length(asleep)}}
    end
  end

  @reload_opts NimbleOptions.new!(
                 resources: [
                   type: {:list, {:struct, Resource}},
                   doc:
                     "the agents whose definitions it reads, as `Wardrik.Resource` patterns: " <>
                       "`acme/*` is an org's and its users'. Every agent's by default."
                 ]
               )

  @doc """
  Reads agents' definitions again on this node, under the context as it is
  now, and answers the agents read and why each that failed did. Agents
  awake take the new definition now; those asleep, as they wake.

      Wardrik.deployment_reload(scope, resources: [Wardrik.Resource.parse!("acme/*")])

  Reach for `:resources` when one org's context changed, such as its
  allowance. The token must allow `deployment.reload`. See
  `Wardrik.Definitions.reload/2`.

  ## Options

  #{NimbleOptions.docs(@reload_opts)}
  """
  @doc group: "Deployment"
  @spec deployment_reload(Scope.t(), keyword()) ::
          {:ok, %{reloaded: [AgentID.t()], failed: [String.t()]}} | {:error, Error.t()}
  def deployment_reload(%Scope{} = scope, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @reload_opts)

    with :ok <- on_deployment(scope, "deployment.reload") do
      reloaded = Definitions.reload(Host.definitions(scope.host), [host: scope.host] ++ opts)
      audited(scope, [{:agents_reloaded, [node()]}], reloaded)
    end
  end

  @page_opts NimbleOptions.new!(
               after: [type: :non_neg_integer, default: 0, doc: "the last sequence already read"],
               limit: [type: :pos_integer, default: 100, doc: "how many to answer at most"]
             )

  @doc """
  A page of the audit, what people changed across the deployment: the
  entries after `:after`, oldest first, or a `:gap` error whose `details`
  hold `oldest` where those were dropped.

  ## Options

  #{NimbleOptions.docs(@page_opts)}
  """
  @doc group: "Deployment"
  @spec deployment_audit(Scope.t(), keyword()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def deployment_audit(%Scope{} = scope, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @page_opts)

    with :ok <- on_deployment(scope, "deployment.audit") do
      store = Host.store(scope.host)

      case Log.read(store, :audit, starting_after: opts[:after], limit: opts[:limit]) do
        {:ok, events} -> {:ok, Entry.numbered(events, :audit, opts[:after])}
        {:gap, oldest} -> {:error, Error.gap(oldest)}
      end
    end
  end

  # -- checking and recording -------------------------------------------------------

  defp authorize(_scope, action, %Thread{agent: agent} = thread) when action in @agents_own,
    do:
      {:error,
       Error.new(
         :invalid,
         "#{thread} is a thread of #{agent}, which holds its definition and triggers; " <>
           "name #{agent} instead."
       )}

  defp authorize(scope, action, target),
    do: Token.authorize(refreshed(scope).token, action, target)

  # The scope, its token renewed once expired with what the host's issuer
  # gives its principal now, so a revocation holds at its next use. A
  # decision or a definition hands the token on, so renews it first.
  defp refreshed(%Scope{host: host, token: token} = scope) do
    if Token.expired?(token),
      do: %{scope | token: Token.refresh(token, as(host, token.principal).token)},
      else: scope
  end

  defp from_now(seconds), do: DateTime.add(DateTime.utc_now(:second), seconds)

  # The deployment is acted on by a token allowing it on `deployment/*`, so
  # one held to an org or a person never learns, nor changes, where any
  # agent runs.
  defp on_deployment(scope, action) do
    case authorize(scope, action, Resource.parse!("deployment/*")) do
      {:error, %Error{type: type}} when type != :unauthorized ->
        {:error, Error.new(:forbidden, "This token may not act on the deployment.")}

      checked ->
        checked
    end
  end

  # Records `actions`, one change, as made by the token's principal, and by
  # whoever acted for them.
  defp audit(%Scope{host: host, token: token}, actions),
    do:
      Audit.record_all(Host.audit(host), actions,
        by: token.principal,
        assumed_by: token.assumed_by
      )

  defp audited(scope, actions, answer) do
    :ok = audit(scope, actions)
    {:ok, answer}
  end

  # -- raising --------------------------------------------------------------------

  @doc "As `agent_ask/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_ask!(Scope.t(), AgentAddress.t(), String.t(), keyword()) ::
          Message.t() | Reply.t() | Waiting.t()
  def agent_ask!(scope, agent, text, opts \\ []),
    do: unwrap(agent_ask(scope, agent, text, opts))

  @doc "As `agent_approve/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_approve!(Scope.t(), AgentAddress.t(), String.t() | [String.t()], keyword()) ::
          %{String.t() => decision()} | Reply.t() | Waiting.t()
  def agent_approve!(scope, agent, calls, opts \\ []),
    do: unwrap(agent_approve(scope, agent, calls, opts))

  @doc "As `agent_deny/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_deny!(Scope.t(), AgentAddress.t(), String.t() | [String.t()], keyword()) ::
          %{String.t() => decision()} | Reply.t() | Waiting.t()
  def agent_deny!(scope, agent, calls, opts \\ []),
    do: unwrap(agent_deny(scope, agent, calls, opts))

  @doc "As `agent_decide/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_decide!(Scope.t(), AgentAddress.t(), %{String.t() => decision()}, keyword()) ::
          %{String.t() => decision()} | Reply.t() | Waiting.t()
  def agent_decide!(scope, agent, decisions, opts \\ []),
    do: unwrap(agent_decide(scope, agent, decisions, opts))

  @doc "As `agent_authorization_read/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_authorization_read!(Scope.t(), AgentAddress.t(), String.t()) ::
          Wardrik.Call.Ask.link()
  def agent_authorization_read!(scope, agent, call),
    do: unwrap(agent_authorization_read(scope, agent, call))

  @doc "As `agent_read/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_read!(Scope.t(), AgentAddress.t()) :: Snapshot.t()
  def agent_read!(scope, agent), do: unwrap(agent_read(scope, agent))

  @doc "As `agent_clear/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_clear!(Scope.t(), AgentAddress.t()) :: Snapshot.t()
  def agent_clear!(scope, agent), do: unwrap(agent_clear(scope, agent))

  @doc "As `agents_list/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agents_list!(Scope.t(), Resource.t()) :: [Member.t()]
  def agents_list!(scope, pattern), do: unwrap(agents_list(scope, pattern))

  @doc "As `agents_parked/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agents_parked!(Scope.t(), Resource.t()) :: [
          {AgentAddress.t(), {Wardrik.Tool.call(), String.t()}}
        ]
  def agents_parked!(scope, pattern), do: unwrap(agents_parked(scope, pattern))

  @doc "As `agent_define/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_define!(Scope.t(), AgentAddress.t(), map(), keyword()) :: Snapshot.t()
  def agent_define!(scope, agent, definition, opts \\ []),
    do: unwrap(agent_define(scope, agent, definition, opts))

  @doc "As `agent_definition_read/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_definition_read!(Scope.t(), AgentAddress.t()) ::
          %{definition: Definition.t(), missing: [String.t()]}
  def agent_definition_read!(scope, agent), do: unwrap(agent_definition_read(scope, agent))

  @doc "As `agent_spawn/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_spawn!(Scope.t(), AgentAddress.t(), keyword()) :: Spawned.t()
  def agent_spawn!(scope, agent, opts \\ []), do: unwrap(agent_spawn(scope, agent, opts))

  @doc "As `agent_move/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_move!(Scope.t(), AgentAddress.t(), node()) :: Member.t()
  def agent_move!(scope, agent, node), do: unwrap(agent_move(scope, agent, node))

  @doc "As `agent_move_preview/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_move_preview!(Scope.t(), AgentAddress.t(), node()) :: Moving.t()
  def agent_move_preview!(scope, agent, node),
    do: unwrap(agent_move_preview(scope, agent, node))

  @doc "As `agent_cancel/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_cancel!(Scope.t(), AgentAddress.t()) :: :ok
  def agent_cancel!(scope, agent), do: unwrap(agent_cancel(scope, agent))

  @doc "As `agents_cancel/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agents_cancel!(Scope.t(), Resource.t()) :: [AgentAddress.t()]
  def agents_cancel!(scope, pattern), do: unwrap(agents_cancel(scope, pattern))

  @doc "As `agent_stop/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_stop!(Scope.t(), AgentAddress.t()) :: Member.t()
  def agent_stop!(scope, agent), do: unwrap(agent_stop(scope, agent))

  @doc "As `agent_forget/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_forget!(Scope.t(), AgentAddress.t()) :: :ok
  def agent_forget!(scope, agent), do: unwrap(agent_forget(scope, agent))

  @doc "As `agents_forget/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agents_forget!(Scope.t(), Resource.t()) :: %{AgentAddress.t() => outcome()}
  def agents_forget!(scope, pattern), do: unwrap(agents_forget(scope, pattern))

  @doc "As `agent_forget_preview/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_forget_preview!(Scope.t(), AgentAddress.t()) :: Forgetting.t()
  def agent_forget_preview!(scope, agent), do: unwrap(agent_forget_preview(scope, agent))

  @doc "As `agents_forget_preview/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agents_forget_preview!(Scope.t(), Resource.t()) :: Forgetting.t()
  def agents_forget_preview!(scope, pattern),
    do: unwrap(agents_forget_preview(scope, pattern))

  @doc "As `agent_calls/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_calls!(Scope.t(), AgentAddress.t()) :: [
          %{call_id: String.t(), name: String.t(), elapsed_ms: non_neg_integer()}
        ]
  def agent_calls!(scope, agent), do: unwrap(agent_calls(scope, agent))

  @doc "As `agent_call_kill/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_call_kill!(Scope.t(), AgentAddress.t(), String.t()) :: :ok
  def agent_call_kill!(scope, agent, call_id),
    do: unwrap(agent_call_kill(scope, agent, call_id))

  @doc "As `agent_trigger_set/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Triggers"
  @spec agent_trigger_set!(Scope.t(), AgentAddress.t(), String.t(), map()) :: map()
  def agent_trigger_set!(scope, agent, name, fields),
    do: unwrap(agent_trigger_set(scope, agent, name, fields))

  @doc "As `agent_trigger_remove/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Triggers"
  @spec agent_trigger_remove!(Scope.t(), AgentAddress.t(), String.t()) :: map()
  def agent_trigger_remove!(scope, agent, name),
    do: unwrap(agent_trigger_remove(scope, agent, name))

  @doc "As `agent_trigger_deliver/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Triggers"
  @spec agent_trigger_deliver!(Scope.t(), AgentID.t(), String.t(), map()) :: atom()
  def agent_trigger_deliver!(scope, agent, trigger, request),
    do: unwrap(agent_trigger_deliver(scope, agent, trigger, request))

  @doc "As `servers_list/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec servers_list!(Scope.t(), Resource.t()) :: [Server.t()]
  def servers_list!(scope, owner), do: unwrap(servers_list(scope, owner))

  @doc "As `servers_add/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec servers_add!(Scope.t(), Resource.t(), Server.t()) :: Server.t()
  def servers_add!(scope, owner, server), do: unwrap(servers_add(scope, owner, server))

  @doc "As `servers_remove/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec servers_remove!(Scope.t(), Resource.t(), String.t()) :: Server.t()
  def servers_remove!(scope, owner, name), do: unwrap(servers_remove(scope, owner, name))

  @doc "As `connections_list/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec connections_list!(Scope.t(), Resource.t()) :: [Connection.t()]
  def connections_list!(scope, owner), do: unwrap(connections_list(scope, owner))

  @doc "As `connections_connect/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec connections_connect!(Scope.t(), Resource.t(), String.t()) :: Connection.t()
  def connections_connect!(scope, owner, provider),
    do: unwrap(connections_connect(scope, owner, provider))

  @doc "As `connections_disconnect/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec connections_disconnect!(Scope.t(), Resource.t(), String.t()) :: Connection.t()
  def connections_disconnect!(scope, owner, provider),
    do: unwrap(connections_disconnect(scope, owner, provider))

  @doc "As `tokens_list/1`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Tokens"
  @spec tokens_list!(Scope.t()) :: [Tokens.Entry.t()]
  def tokens_list!(scope), do: unwrap(tokens_list(scope))

  @doc "As `tokens_create/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Tokens"
  @spec tokens_create!(Scope.t(), String.t(), [Statement.t()], keyword()) :: Tokens.Entry.t()
  def tokens_create!(scope, name, statements, opts \\ []),
    do: unwrap(tokens_create(scope, name, statements, opts))

  @doc "As `tokens_revoke/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Tokens"
  @spec tokens_revoke!(Scope.t(), String.t()) :: Tokens.Entry.t()
  def tokens_revoke!(scope, id), do: unwrap(tokens_revoke(scope, id))

  @doc "As `deployment_nodes/1`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Deployment"
  @spec deployment_nodes!(Scope.t()) :: Nodes.t()
  def deployment_nodes!(scope), do: unwrap(deployment_nodes(scope))

  @doc "As `deployment_reload/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Deployment"
  @spec deployment_reload!(Scope.t(), keyword()) :: %{
          reloaded: [AgentID.t()],
          failed: [String.t()]
        }
  def deployment_reload!(scope, opts \\ []), do: unwrap(deployment_reload(scope, opts))

  @doc "As `subscribe/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Events"
  @spec subscribe!(Scope.t(), keyword()) :: :ok
  def subscribe!(scope, opts \\ []), do: unwrap(subscribe(scope, opts))

  @doc "As `events/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Events"
  @spec events!(Scope.t(), keyword()) :: Enumerable.t(Wardrik.Event.t())
  def events!(scope, opts \\ []), do: unwrap(events(scope, opts))

  @doc "As `events_head/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Events"
  @spec events_head!(Scope.t(), keyword()) :: String.t()
  def events_head!(scope, opts \\ []), do: unwrap(events_head(scope, opts))

  @doc "As `deployment_audit/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Deployment"
  @spec deployment_audit!(Scope.t(), keyword()) :: [Entry.t()]
  def deployment_audit!(scope, opts \\ []), do: unwrap(deployment_audit(scope, opts))

  defp unwrap({:ok, value}), do: value
  defp unwrap({:waiting, waiting}), do: waiting
  defp unwrap(:ok), do: :ok
  defp unwrap({:error, error}), do: raise(error)
end
