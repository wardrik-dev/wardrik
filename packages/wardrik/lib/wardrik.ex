defmodule Wardrik do
  @moduledoc """
  Wardrik inside an application: agents kept in the application's own store,
  started in its own tree, and reached as the people it knows.

  `new/1` reads the options once, into a value the application starts and
  makes its callers with:

      wardrik =
        Wardrik.new(
          store: Wardrik.store(repo: MyApp.Repo),
          issuer: %MyApp.Issuer{},
          context: Wardrik.context(tools: [MyApp.Tools.Search])
        )

      children = [MyApp.Repo, {Wardrik, wardrik}, MyAppWeb.Endpoint]

      scope = Wardrik.as(wardrik, maria)
      {:ok, _snapshot} = Wardrik.agent_define(scope, agent, %{"instructions" => "Be brief."})
      {:ok, message} = Wardrik.agent_ask(scope, agent, "Where is order 1001?")

  `{Wardrik, wardrik}` starts, in order, under `:rest_for_one`, so a restart
  of one restarts everything after it:

  | Child | What it runs |
  | --- | --- |
  | the store | where everything is kept |
  | `Wardrik.Core` | the agents |
  | the meters | what budgets count in |
  | the triggers | clocks, feeds and webhooks |

  Each agent's definition is kept in the store, read against what
  `:context` lets it name, and so are the files it works on.

  The store is a value of its own, made by `store/1`, so a seam that keeps
  something, such as a vault of credentials, is made with the same one. So
  is the context, made by `context/1`, so an application can read it
  differently for each agent. A
  surface the application starts after Wardrik, such as the HTTP API, takes
  the store or `host/1`. A node runs one Wardrik, since core's own
  processes are registered under their module names.

  ## Acting on the agents

  Everything an application does with its agents goes through this module,
  in a `Wardrik.Scope`, its first argument: the host, and the
  `Wardrik.Token` saying who acts and what they may do. Each function is
  named for what it acts on, then what it does, as `agent_ask/4` and
  `servers_add/3`, checks that the token allows its action, the same name
  written `agent.ask` and `servers.add`, before anything happens, and
  records what it changes in the audit:

    * a read answers what it read, such as `agent_read/2`'s snapshot
    * a change answers what it made, such as `agent_define/4`'s agent
    * a change whose outcome the agent's log shows answers that it was
      taken, as `agent_ask/4` answers the message queued; `agent_subscribe/2`
      and `agent_stream/3` follow what happens next
    * a removal answers what it removed, as it was, as an Ecto delete does
    * a change whose outcome nothing can answer at once answers `:ok`, as
      `agent_cancel/2` and `agent_forget/2` do
    * a preview, as `agent_move_preview/3`, makes the same check as its
      change and answers what the change would do, recording nothing, so a
      surface can show it and ask first; the change works it out again

  Each answers `{:ok, value}`, `:ok` or `{:error, %Wardrik.Error{}}`, and
  has a variant ending in `!` that answers the value or raises the error.

  ## Options

    * `:store` - where everything is kept, as `store/1` makes it. Required.
    * `:context` - what each agent's definition may name: `context/1`'s, or
      a value of the application's own implementing
      `WardrikDefinition.Contexts`, which gives each agent its context.
      `context([])` by default.
    * `:issuer`, `:credentials`, `:connections`, `:servers`, `:tokens`,
      `:triggers`, `:dispatch`, `:llm` - the host's seams, each a value
      implementing core's protocol of that name, as `Wardrik.Host` lists
      them. One left out is that protocol's default: tokens allowing
      nothing, no credentials, every model call made through ReqLLM, and so
      on.
    * `:expires` - how long tokens last, in seconds: `api:`, those
      `tokens_create/4` makes, 90 days by default; `session:`, those
      `as/3` issues, 12 hours by default.
    * `:fleet` - the options of `Wardrik.Fleet.Supervisor`.
  """

  use Supervisor

  require Logger

  alias Wardrik.Agent
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.AgentID
  alias Wardrik.Audit
  alias Wardrik.Connections
  alias Wardrik.Connections.Connection
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Deployment.Nodes
  alias Wardrik.Error
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Fleet
  alias Wardrik.Fleet.Member
  alias Wardrik.Forgetting
  alias Wardrik.Host
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Moving
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Scope
  alias Wardrik.Servers
  alias Wardrik.Servers.Server
  alias Wardrik.Spawned
  alias Wardrik.Statement
  alias Wardrik.Token
  alias Wardrik.Tokens
  alias WardrikDefinition.Context

  @enforce_keys [:host]
  defstruct [:host, fleet: []]

  @type t() :: %__MODULE__{host: Wardrik.Host.t(), fleet: keyword()}

  @typedoc "A decision on a call an agent waits on."
  @type decision() :: :approve | {:approve, String.t()} | {:deny, String.t()}

  @typedoc "What became of an agent a forget reached: removed, kept with why, or not removed with why."
  @type outcome() :: :forgotten | {:kept, String.t()} | {:failed, String.t()}

  @seams [:issuer, :credentials, :connections, :servers, :tokens, :triggers, :dispatch, :llm]

  # The setting that names each store.
  @stores [
    repo: WardrikEcto.Store,
    url: WardrikEcto.Store,
    bucket: WardrikS3.Store,
    data_dir: WardrikStore.EKV
  ]

  @doc """
  Wardrik as `opts` describe it, made without starting anything. Raises
  where an option is not one of those above, or where `:store` is missing.
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    opts = Keyword.validate!(opts, [:store, :expires, fleet: [], context: context([])] ++ @seams)
    store = Keyword.fetch!(opts, :store)

    host =
      Wardrik.Host.new(
        [
          store: store,
          definitions: %WardrikDefinition.Kept{store: store, contexts: opts[:context]},
          workspace: %WardrikWorkspace.Backend.Store{store: store}
        ] ++ Keyword.take(opts, [:expires | @seams])
      )

    %__MODULE__{host: host, fleet: opts[:fleet]}
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

      Wardrik.store(repo: MyApp.Repo)
  """
  @spec store(keyword()) :: WardrikStore.t()
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
  What a definition may name, as the fields of `WardrikDefinition.Context`
  in `fields`: the `tools` the application ships, the MCP `servers`, the
  `policies`, and so on. `sources` names `self`, an agent's operations on
  itself, and `agents`, those on the other agents of its org, unless
  given.

      Wardrik.context(tools: [MyApp.Tools.Search])
  """
  @spec context(keyword()) :: Context.t()
  def context(fields) do
    struct!(
      Context,
      Keyword.merge(
        [sources: [self: Wardrik.Catalog.Self, agents: Wardrik.Catalog.Agents]],
        fields
      )
    )
  end

  @doc "The `Wardrik.Host` the agents run on, for a surface started after Wardrik."
  @spec host(t()) :: Wardrik.Host.t()
  def host(%__MODULE__{host: host}), do: host

  @doc "The child that runs `wardrik`."
  @spec child_spec(t()) :: Supervisor.child_spec()
  def child_spec(%__MODULE__{} = wardrik),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [wardrik]}, type: :supervisor}

  @doc "Starts `wardrik`, as `child_spec/1` does."
  @spec start_link(t()) :: Supervisor.on_start()
  def start_link(%__MODULE__{} = wardrik),
    do: Supervisor.start_link(__MODULE__, wardrik, name: __MODULE__)

  @impl true
  def init(%__MODULE__{host: host, fleet: fleet}) do
    store = Wardrik.Host.store(host)

    children = [
      {WardrikStore, store},
      {Wardrik.Core, host: host, fleet: fleet},
      {WardrikPolicy.Supervisor, store: store},
      {WardrikTrigger, store: store, host: host}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  The scope `principal` acts in on the agents of `wardrik`, or of the
  `Wardrik.Host` a surface was started with: the token the host's
  `Wardrik.Issuer` issues them, which reads `opts` as it reads them,
  expiring as the host's `:session` expiry says. Each function here
  refreshes a token past its expiry through the issuer as it uses it, so
  whatever holds the scope keeps working, held to what the issuer gives
  the principal now (see `Wardrik.Token.refresh/2`).

      scope = Wardrik.as(wardrik, maria)
  """
  @doc group: "Scopes"
  @spec as(t() | Host.t(), Principal.t(), keyword()) :: Scope.t()
  def as(wardrik_or_host, principal, opts \\ [])
  def as(%__MODULE__{host: host}, principal, opts), do: as(host, principal, opts)

  def as(%Host{} = host, principal, opts) do
    token = Wardrik.Issuer.issue(Host.issuer(host), principal, opts)
    Scope.new(host, %{token | expires: from_now(Host.expires(host, :session))})
  end

  # -- talking to an agent ----------------------------------------------------

  @ask_opts NimbleOptions.new!(
              id: [
                type: {:or, [:string, nil]},
                doc: "the message's id, which the agent takes once; a new UUIDv7 by default"
              ]
            )

  @doc """
  Sends `agent` `text` from whoever acts with the scope's token, its
  `Wardrik.Token.actor/1`, which it answers in a turn of its own.
  Acknowledged with the `Wardrik.Agent.Message` queued, whose `sequence` is
  where the agent's log stood: the turn that answers it is written after
  it, so `agent_stream/3` from there reads it. An agent's scope, as
  `Wardrik.Scope.agent/2` makes it, is answered back.

  ## Options

  #{NimbleOptions.docs(@ask_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_ask(Scope.t(), AgentID.t(), String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, Error.t()}
  def agent_ask(%Scope{} = scope, %AgentID{} = agent, text, opts \\ [])
      when is_binary(text) do
    opts = NimbleOptions.validate!(opts, @ask_opts)

    with :ok <- said(text, opts[:id]),
         :ok <- authorize(scope, "agent.ask", agent),
         {:ok, %Snapshot{sequence: sequence}} <- agent_snapshot(agent, scope.host) do
      message =
        Message.new(text, opts[:id], sender: Token.actor(scope.token), reply_to: scope.reply_to)

      message = %{message | sequence: sequence}

      case Agent.queue(agent, message, host: scope.host) do
        :ok -> {:ok, message}
        {:error, :not_found} -> {:error, Error.no_agent(agent)}
      end
    end
  end

  defp said("", _id), do: {:error, Error.new(:invalid, "A message has text to send")}
  defp said(_text, ""), do: {:error, Error.new(:invalid, "A message's id is text")}
  defp said(_text, _id), do: :ok

  @doc """
  Sends this process every entry `agent`'s log writes from now on, as
  `%Wardrik.Event.Log.Entry{}` messages, where the scope may read its events.
  """
  @doc group: "Talking to an agent"
  @spec agent_subscribe(Scope.t(), AgentID.t()) :: :ok | {:error, Error.t()}
  def agent_subscribe(%Scope{} = scope, %AgentID{} = agent) do
    with :ok <- authorize(scope, "agent.events", agent), do: Log.subscribe(agent)
  end

  @stream_opts NimbleOptions.new!(
                 after: [
                   type: :non_neg_integer,
                   default: 0,
                   doc: "the sequence it follows from, such as a message's or a snapshot's"
                 ]
               )

  @doc """
  `agent`'s log as a lazy `Stream` of `Wardrik.Event.Log.Entry`s: every one
  written after `:after`, then each as the agent writes it, until the
  process taking it stops. It subscribes the process taking it while it
  runs, so it reads each entry once, in order.

      {:ok, message} = Wardrik.agent_ask(scope, agent, "Summarise the inbox")
      {:ok, stream} = Wardrik.agent_stream(scope, agent, after: message.sequence)

      Enum.find(stream, &(&1.event["type"] == "wardrik.run.completed"))

  ## Options

  #{NimbleOptions.docs(@stream_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_stream(Scope.t(), AgentID.t(), keyword()) ::
          {:ok, Enumerable.t(Entry.t())} | {:error, Error.t()}
  def agent_stream(%Scope{} = scope, %AgentID{} = agent, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @stream_opts)

    with :ok <- authorize(scope, "agent.events", agent),
         do: {:ok, Wardrik.Stream.new(Host.store(scope.host), agent, opts[:after])}
  end

  @page_opts NimbleOptions.new!(
               after: [type: :non_neg_integer, default: 0, doc: "the last sequence already read"],
               limit: [type: :pos_integer, default: 100, doc: "how many to answer at most"]
             )

  @doc """
  A page of `agent`'s log: the entries after `:after`, oldest first, or a
  `:gap` error whose `details` hold `oldest` where those were dropped.

  ## Options

  #{NimbleOptions.docs(@page_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_events(Scope.t(), AgentID.t(), keyword()) ::
          {:ok, [Entry.t()]} | {:error, Error.t()}
  def agent_events(%Scope{} = scope, %AgentID{} = agent, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @page_opts)
    with :ok <- authorize(scope, "agent.events", agent), do: page(scope, agent, opts)
  end

  # A page of the log `log`, an agent's or the audit, as `opts` ask for it.
  defp page(scope, log, opts) do
    case Log.read(Host.store(scope.host), log, starting_after: opts[:after], limit: opts[:limit]) do
      {:ok, events} -> {:ok, Entry.numbered(events, opts[:after])}
      {:gap, oldest} -> {:error, Error.gap(oldest)}
    end
  end

  @approve_opts NimbleOptions.new!(note: [type: :string, doc: "what the agent is told with it"])

  @doc """
  Runs the call, or each of the calls, `agent` waits on a person for.
  Acknowledged with the decisions taken, by call id; the agent's log says
  what its turn does next.

  ## Options

  #{NimbleOptions.docs(@approve_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_approve(Scope.t(), AgentID.t(), String.t() | [String.t()], keyword()) ::
          {:ok, %{String.t() => decision()}} | {:error, Error.t()}
  def agent_approve(%Scope{} = scope, %AgentID{} = agent, calls, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @approve_opts)
    decide(scope, agent, calls, if(opts[:note], do: {:approve, opts[:note]}, else: :approve))
  end

  @deny_opts NimbleOptions.new!(
               reason: [
                 type: :string,
                 default: "A person refused this call.",
                 doc: "why, as the agent is told"
               ]
             )

  @doc """
  Refuses the call, or each of the calls, `agent` waits on a person for.
  Acknowledged with the decisions taken, by call id.

  ## Options

  #{NimbleOptions.docs(@deny_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_deny(Scope.t(), AgentID.t(), String.t() | [String.t()], keyword()) ::
          {:ok, %{String.t() => decision()}} | {:error, Error.t()}
  def agent_deny(%Scope{} = scope, %AgentID{} = agent, calls, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @deny_opts)
    decide(scope, agent, calls, {:deny, opts[:reason]})
  end

  defp decide(scope, agent, calls, decision),
    do: agent_decide(scope, agent, Map.new(List.wrap(calls), &{&1, decision}))

  @doc """
  Decides several of the calls `agent` waits on at once, each by its id:
  `:approve`, `{:approve, note}` or `{:deny, reason}`, as `agent_approve/4`
  and `agent_deny/4` decide one kind. Acknowledged with the decisions taken;
  calls left out stay waiting.

  A scope that may read the agent may ask; the agent takes the decisions
  from one whose token allows `agent.decide` on it, or whose principal asked
  for the turn that waits and acts directly, as `Wardrik.Agent.decide/3`
  says, and answers anyone else `:forbidden`.
  """
  @doc group: "Talking to an agent"
  @spec agent_decide(Scope.t(), AgentID.t(), %{String.t() => decision()}) ::
          {:ok, %{String.t() => decision()}} | {:error, Error.t()}
  def agent_decide(%Scope{} = scope, %AgentID{} = agent, decisions) when is_map(decisions) do
    scope = refreshed(scope)

    with :ok <- authorize(scope, "agent.read", agent) do
      case Agent.decide(agent, decisions, token: scope.token, host: scope.host) do
        :ok -> {:ok, decisions}
        {:error, reason} -> {:error, undecided(reason, agent, decisions)}
      end
    end
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
  @spec agent_authorization_read(Scope.t(), AgentID.t(), String.t()) ::
          {:ok, Wardrik.Call.Ask.link()} | {:error, Error.t()}
  def agent_authorization_read(%Scope{} = scope, %AgentID{} = agent, call) do
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
  @spec agent_read(Scope.t(), AgentID.t()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def agent_read(%Scope{} = scope, %AgentID{} = agent) do
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
  @spec agent_clear(Scope.t(), AgentID.t()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def agent_clear(%Scope{} = scope, %AgentID{} = agent) do
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
          {:ok, [{AgentID.t(), {Wardrik.Tool.call(), String.t()}}]} | {:error, Error.t()}
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
  names, ahead of its own; the host's definitions read that policy by its
  name, and keep both with it, so it runs under them each time it starts.

  ## Options

  #{NimbleOptions.docs(@define_opts)}
  """
  @doc group: "Agent lifecycle"
  @spec agent_define(Scope.t(), AgentID.t(), map(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Error.t()}
  def agent_define(%Scope{} = scope, %AgentID{} = agent, definition, opts \\ [])
      when is_map(definition) do
    opts = NimbleOptions.validate!(opts, @define_opts)
    scope = refreshed(scope)

    with :ok <- authorize(scope, "agent.define", agent),
         {:ok, spec} <- defined(scope, agent, definition, opts[:held]),
         {:ok, _pid} <-
           started(Fleet.put(%{spec | hooks: opts[:held] ++ List.wrap(spec.hooks)}), agent) do
      audit(scope, [{:agent_defined, agent}])
      agent_snapshot(agent, scope.host)
    end
  end

  defp defined(scope, agent, fields, held) do
    case Definition.put(Host.definitions(scope.host), agent,
           definition: fields,
           token: scope.token,
           held: held
         ) do
      {:ok, %{id: ^agent} = spec} ->
        {:ok, spec}

      {:ok, spec} ->
        raise ArgumentError, "the host's definitions wrote a spec for #{spec.id}, not #{agent}"

      :unsupported ->
        {:error, Error.new(:unsupported, "This server does not define agents.")}

      refused ->
        refused(refused)
    end
  end

  # A refusal of the host's definitions, as an error of its kind.
  defp refused({:error, :conflict, message}), do: {:error, Error.new(:conflict, message)}
  defp refused({:error, message}), do: {:error, Error.new(:invalid, message)}

  @doc "`agent`'s definition as it was last put, and the tools it names that offer nothing yet."
  @doc group: "Agent lifecycle"
  @spec agent_definition_read(Scope.t(), AgentID.t()) ::
          {:ok, Wardrik.Definition.Read.t()} | {:error, Error.t()}
  def agent_definition_read(%Scope{} = scope, %AgentID{} = agent) do
    with :ok <- authorize(scope, "agent.definition.read", agent) do
      case Definition.get(Host.definitions(scope.host), agent) do
        {:ok, read} ->
          {:ok, read}

        {:error, :not_found} ->
          {:error, undefined(agent)}

        :unsupported ->
          {:error, Error.new(:unsupported, "This server does not keep agents' definitions.")}
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
  starts on its definition, and one nothing defines yet is defined as the
  host's `c:Wardrik.Definition.create/2` says.

  ## Options

  #{NimbleOptions.docs(@spawn_opts)}
  """
  @doc group: "Agent lifecycle"
  @spec agent_spawn(Scope.t(), AgentID.t(), keyword()) ::
          {:ok, Spawned.t()} | {:error, Error.t()}
  def agent_spawn(%Scope{} = scope, %AgentID{} = agent, opts \\ []) do
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
    case {Fleet.lookup(agent, host: scope.host),
          Definition.current(Host.definitions(scope.host), agent)} do
      {%Member{asleep: false}, _current} -> {:running, nil}
      {_member, {:ok, spec}} -> {:definition, spec}
      {%Member{asleep: true}, :none} -> {:store, nil}
      {nil, :none} -> {:new, nil}
    end
  end

  # Starts the agent as it was found, on `node`, or wherever the fleet puts
  # it where `nil`: what the audit records of it.
  defp spawn(_scope, _agent, {:running, nil}, _node), do: {:ok, []}

  defp spawn(_scope, agent, {:store, nil}, node),
    do: agent |> Fleet.spawn(if(node, do: [node: node], else: [])) |> spawned(agent)

  defp spawn(_scope, agent, {:definition, spec}, node), do: spec |> put(node) |> spawned(agent)

  defp spawn(scope, agent, {:new, nil}, node) do
    case Definition.create(Host.definitions(scope.host), agent) do
      {:ok, spec} -> spec |> put(node) |> spawned(agent)
      :unsupported -> {:error, Error.no_agent(agent)}
      refused -> refused(refused)
    end
  end

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
  @spec agent_move(Scope.t(), AgentID.t(), node()) :: {:ok, Member.t()} | {:error, Error.t()}
  def agent_move(%Scope{} = scope, %AgentID{} = agent, node) when is_atom(node) do
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
  @spec agent_move_preview(Scope.t(), AgentID.t(), node()) ::
          {:ok, Moving.t()} | {:error, Error.t()}
  def agent_move_preview(%Scope{} = scope, %AgentID{} = agent, node) when is_atom(node) do
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
  @spec agent_cancel(Scope.t(), AgentID.t()) :: :ok | {:error, Error.t()}
  def agent_cancel(%Scope{} = scope, %AgentID{} = agent) do
    with :ok <- authorize(scope, "agent.cancel", agent),
         {:ok, member} <- member(agent, scope.host),
         do: audit(scope, for(id <- cancelled([member]), do: {:agent_cancelled, id}))
  end

  @doc "Ends the turn of every agent `pattern` covers, and answers those it ended."
  @doc group: "Agent lifecycle"
  @spec agents_cancel(Scope.t(), Resource.t()) :: {:ok, [AgentID.t()]} | {:error, Error.t()}
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
  @spec agent_stop(Scope.t(), AgentID.t()) :: {:ok, Member.t()} | {:error, Error.t()}
  def agent_stop(%Scope{} = scope, %AgentID{} = agent) do
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
  @spec agent_forget(Scope.t(), AgentID.t()) :: :ok | {:error, Error.t()}
  def agent_forget(%Scope{} = scope, %AgentID{} = agent) do
    with {:ok, _forgetting} <- forgetting(scope, agent) do
      case Definitions.forget(scope.host, agent) do
        {:ok, kept} -> forgotten(scope, agent, kept)
        {:error, :conflict, why} -> {:error, Error.new(:conflict, why)}
      end
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
  @spec agent_forget_preview(Scope.t(), AgentID.t()) ::
          {:ok, Forgetting.t()} | {:error, Error.t()}
  def agent_forget_preview(%Scope{} = scope, %AgentID{} = agent) do
    forgetting(scope, agent)
  end

  defp forgetting(scope, agent) do
    with :ok <- authorize(scope, "agent.forget", agent),
         :ok <- kept(scope.host, agent) do
      case Definition.editable(Host.definitions(scope.host), agent) do
        :ok -> {:ok, %Forgetting{agents: [agent], kept: []}}
        {:error, :conflict, why} -> {:error, Error.new(:conflict, why)}
      end
    end
  end

  defp kept(host, agent) do
    if Fleet.stored?(agent) or Definitions.kept?(host, agent),
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
          {:ok, %{AgentID.t() => outcome()}} | {:error, Error.t()}
  def agents_forget(%Scope{} = scope, pattern) do
    with {:ok, %Forgetting{agents: agents, kept: kept}} <- forgetting_under(scope, pattern) do
      outcomes = Map.new(agents, &{&1, forget(scope.host, &1)})
      audit(scope, for({id, :forgotten} <- outcomes, do: {:agent_forgotten, id, pattern}))
      {:ok, Map.merge(outcomes, Map.new(kept, fn {id, why} -> {id, {:kept, why}} end))}
    end
  end

  defp forget(host, agent) do
    with {:ok, _kept} <- Definitions.forget(host, agent),
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
            do: {id, Definition.editable(definitions, id)}

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
  @spec agent_calls(Scope.t(), AgentID.t()) ::
          {:ok, [%{call_id: String.t(), name: String.t(), elapsed_ms: non_neg_integer()}]}
          | {:error, Error.t()}
  def agent_calls(%Scope{} = scope, %AgentID{} = agent) do
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
  @spec agent_call_kill(Scope.t(), AgentID.t(), String.t()) :: :ok | {:error, Error.t()}
  def agent_call_kill(%Scope{} = scope, %AgentID{} = agent, call_id)
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
  it.
  """
  @doc group: "Triggers"
  @spec agent_trigger_set(Scope.t(), AgentID.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def agent_trigger_set(%Scope{} = scope, %AgentID{} = agent, name, fields)
      when is_binary(name) and is_map(fields) do
    with :ok <- authorize(scope, "agent.trigger.set", agent),
         {:ok, trigger} <- trigger_set(scope, agent, name, fields),
         do: audited(scope, [{:trigger_set, agent, name}], trigger)
  end

  defp trigger_set(scope, agent, name, fields) do
    case Definition.put_trigger(Host.definitions(scope.host), agent, name, fields: fields) do
      {:ok, _created_or_changed, trigger} -> {:ok, trigger}
      {:error, :not_found} -> {:error, undefined(agent)}
      :unsupported -> {:error, Error.new(:unsupported, "This server keeps no triggers.")}
      refused -> refused(refused)
    end
  end

  @doc "Removes `agent`'s trigger `name`, and answers it as `agent_trigger_set/4` would."
  @doc group: "Triggers"
  @spec agent_trigger_remove(Scope.t(), AgentID.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def agent_trigger_remove(%Scope{} = scope, %AgentID{} = agent, name) when is_binary(name) do
    with :ok <- authorize(scope, "agent.trigger.remove", agent),
         {:ok, trigger} <- trigger_removed(scope, agent, name),
         do: audited(scope, [{:trigger_removed, agent, name}], trigger)
  end

  defp trigger_removed(scope, agent, name) do
    case Definition.delete_trigger(Host.definitions(scope.host), agent, name) do
      {:ok, trigger} -> {:ok, trigger}
      {:error, :not_found} -> {:error, Error.new(:not_found, "#{agent} has no trigger #{name}.")}
      {:error, :conflict, message} -> {:error, Error.new(:conflict, message)}
      :unsupported -> {:error, Error.new(:unsupported, "This server keeps no triggers.")}
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
            held_by: held_by(owner)
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

  # An owner forgets only an account of their own.
  defp held_by(owner), do: if(Resource.org(owner) == owner, do: :org, else: :person)

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

  @doc """
  Has every node the host's definitions name in
  `c:Wardrik.Definition.reloading/1` read its agents' definitions again, and
  answers those nodes.
  """
  @doc group: "Deployment"
  @spec deployment_reload(Scope.t()) :: {:ok, [node()]} | {:error, Error.t()}
  def deployment_reload(%Scope{} = scope) do
    with :ok <- on_deployment(scope, "deployment.reload") do
      definitions = Host.definitions(scope.host)

      case Definition.reloading(definitions) do
        [] ->
          {:error, Error.new(:unsupported, "This deployment reads no definitions again.")}

        nodes ->
          :ok = Definitions.reload_on(scope.host, nodes)
          audited(scope, [{:agents_reloaded, nodes}], nodes)
      end
    end
  end

  @doc """
  A page of the audit, what people changed across the deployment, as
  `agent_events/3` reads an agent's log.

  ## Options

  #{NimbleOptions.docs(@page_opts)}
  """
  @doc group: "Deployment"
  @spec deployment_audit(Scope.t(), keyword()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def deployment_audit(%Scope{} = scope, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @page_opts)
    with :ok <- on_deployment(scope, "deployment.audit"), do: page(scope, :audit, opts)
  end

  # -- checking and recording -------------------------------------------------------

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
  @spec agent_ask!(Scope.t(), AgentID.t(), String.t(), keyword()) :: Message.t()
  def agent_ask!(scope, agent, text, opts \\ []),
    do: unwrap(agent_ask(scope, agent, text, opts))

  @doc "As `agent_subscribe/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_subscribe!(Scope.t(), AgentID.t()) :: :ok
  def agent_subscribe!(scope, agent), do: unwrap(agent_subscribe(scope, agent))

  @doc "As `agent_stream/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_stream!(Scope.t(), AgentID.t(), keyword()) :: Enumerable.t(Entry.t())
  def agent_stream!(scope, agent, opts \\ []), do: unwrap(agent_stream(scope, agent, opts))

  @doc "As `agent_events/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_events!(Scope.t(), AgentID.t(), keyword()) :: [Entry.t()]
  def agent_events!(scope, agent, opts \\ []), do: unwrap(agent_events(scope, agent, opts))

  @doc "As `agent_approve/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_approve!(Scope.t(), AgentID.t(), String.t() | [String.t()], keyword()) :: %{
          String.t() => decision()
        }
  def agent_approve!(scope, agent, calls, opts \\ []),
    do: unwrap(agent_approve(scope, agent, calls, opts))

  @doc "As `agent_deny/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_deny!(Scope.t(), AgentID.t(), String.t() | [String.t()], keyword()) :: %{
          String.t() => decision()
        }
  def agent_deny!(scope, agent, calls, opts \\ []),
    do: unwrap(agent_deny(scope, agent, calls, opts))

  @doc "As `agent_decide/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_decide!(Scope.t(), AgentID.t(), %{String.t() => decision()}) ::
          %{String.t() => decision()}
  def agent_decide!(scope, agent, decisions),
    do: unwrap(agent_decide(scope, agent, decisions))

  @doc "As `agent_authorization_read/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_authorization_read!(Scope.t(), AgentID.t(), String.t()) :: Wardrik.Call.Ask.link()
  def agent_authorization_read!(scope, agent, call),
    do: unwrap(agent_authorization_read(scope, agent, call))

  @doc "As `agent_read/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_read!(Scope.t(), AgentID.t()) :: Snapshot.t()
  def agent_read!(scope, agent), do: unwrap(agent_read(scope, agent))

  @doc "As `agent_clear/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_clear!(Scope.t(), AgentID.t()) :: Snapshot.t()
  def agent_clear!(scope, agent), do: unwrap(agent_clear(scope, agent))

  @doc "As `agents_list/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agents_list!(Scope.t(), Resource.t()) :: [Member.t()]
  def agents_list!(scope, pattern), do: unwrap(agents_list(scope, pattern))

  @doc "As `agents_parked/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agents_parked!(Scope.t(), Resource.t()) :: [
          {AgentID.t(), {Wardrik.Tool.call(), String.t()}}
        ]
  def agents_parked!(scope, pattern), do: unwrap(agents_parked(scope, pattern))

  @doc "As `agent_define/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_define!(Scope.t(), AgentID.t(), map(), keyword()) :: Snapshot.t()
  def agent_define!(scope, agent, definition, opts \\ []),
    do: unwrap(agent_define(scope, agent, definition, opts))

  @doc "As `agent_definition_read/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_definition_read!(Scope.t(), AgentID.t()) :: Wardrik.Definition.Read.t()
  def agent_definition_read!(scope, agent), do: unwrap(agent_definition_read(scope, agent))

  @doc "As `agent_spawn/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_spawn!(Scope.t(), AgentID.t(), keyword()) :: Spawned.t()
  def agent_spawn!(scope, agent, opts \\ []), do: unwrap(agent_spawn(scope, agent, opts))

  @doc "As `agent_move/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_move!(Scope.t(), AgentID.t(), node()) :: Member.t()
  def agent_move!(scope, agent, node), do: unwrap(agent_move(scope, agent, node))

  @doc "As `agent_move_preview/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_move_preview!(Scope.t(), AgentID.t(), node()) :: Moving.t()
  def agent_move_preview!(scope, agent, node),
    do: unwrap(agent_move_preview(scope, agent, node))

  @doc "As `agent_cancel/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_cancel!(Scope.t(), AgentID.t()) :: :ok
  def agent_cancel!(scope, agent), do: unwrap(agent_cancel(scope, agent))

  @doc "As `agents_cancel/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agents_cancel!(Scope.t(), Resource.t()) :: [AgentID.t()]
  def agents_cancel!(scope, pattern), do: unwrap(agents_cancel(scope, pattern))

  @doc "As `agent_stop/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_stop!(Scope.t(), AgentID.t()) :: Member.t()
  def agent_stop!(scope, agent), do: unwrap(agent_stop(scope, agent))

  @doc "As `agent_forget/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_forget!(Scope.t(), AgentID.t()) :: :ok
  def agent_forget!(scope, agent), do: unwrap(agent_forget(scope, agent))

  @doc "As `agents_forget/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agents_forget!(Scope.t(), Resource.t()) :: %{AgentID.t() => outcome()}
  def agents_forget!(scope, pattern), do: unwrap(agents_forget(scope, pattern))

  @doc "As `agent_forget_preview/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_forget_preview!(Scope.t(), AgentID.t()) :: Forgetting.t()
  def agent_forget_preview!(scope, agent), do: unwrap(agent_forget_preview(scope, agent))

  @doc "As `agents_forget_preview/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agents_forget_preview!(Scope.t(), Resource.t()) :: Forgetting.t()
  def agents_forget_preview!(scope, pattern),
    do: unwrap(agents_forget_preview(scope, pattern))

  @doc "As `agent_calls/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_calls!(Scope.t(), AgentID.t()) :: [
          %{call_id: String.t(), name: String.t(), elapsed_ms: non_neg_integer()}
        ]
  def agent_calls!(scope, agent), do: unwrap(agent_calls(scope, agent))

  @doc "As `agent_call_kill/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_call_kill!(Scope.t(), AgentID.t(), String.t()) :: :ok
  def agent_call_kill!(scope, agent, call_id),
    do: unwrap(agent_call_kill(scope, agent, call_id))

  @doc "As `agent_trigger_set/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Triggers"
  @spec agent_trigger_set!(Scope.t(), AgentID.t(), String.t(), map()) :: map()
  def agent_trigger_set!(scope, agent, name, fields),
    do: unwrap(agent_trigger_set(scope, agent, name, fields))

  @doc "As `agent_trigger_remove/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Triggers"
  @spec agent_trigger_remove!(Scope.t(), AgentID.t(), String.t()) :: map()
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

  @doc "As `deployment_reload/1`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Deployment"
  @spec deployment_reload!(Scope.t()) :: [node()]
  def deployment_reload!(scope), do: unwrap(deployment_reload(scope))

  @doc "As `deployment_audit/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Deployment"
  @spec deployment_audit!(Scope.t(), keyword()) :: [Entry.t()]
  def deployment_audit!(scope, opts \\ []), do: unwrap(deployment_audit(scope, opts))

  defp unwrap({:ok, value}), do: value
  defp unwrap(:ok), do: :ok
  defp unwrap({:error, error}), do: raise(error)
end
