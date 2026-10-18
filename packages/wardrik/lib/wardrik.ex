defmodule Wardrik do
  @moduledoc """
  Wardrik inside an application: agents kept in the application's own store,
  started in its own tree, and reached as the people it knows.

  `new/1` reads the options once, into a value the application starts and
  makes its callers with:

      wardrik =
        Wardrik.new(
          store: Wardrik.store(repo: MyApp.Repo),
          grants: %MyApp.Grants{},
          context: Wardrik.context(tools: [MyApp.Tools.Search])
        )

      children = [MyApp.Repo, {Wardrik, wardrik}, MyAppWeb.Endpoint]

      session = Wardrik.as(wardrik, maria)
      {:ok, _snapshot} = Wardrik.agent_define(session, agent, %{"instructions" => "Be brief."})
      {:ok, message} = Wardrik.agent_ask(session, agent, "Where is order 1001?")

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
  as a `Wardrik.Session`: who acts, with what grant. Each function is named
  for what it acts on, then what it does, as `agent_ask/4` and
  `servers_add/3`, and checks the session's grant before anything happens,
  recording what it changes in the audit:

    * a read answers what it read, such as `agent_read/2`'s snapshot
    * a change answers what it made, such as `agent_define/3`'s agent
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
    * `:grants`, `:credentials`, `:connections`, `:servers`, `:tokens`,
      `:triggers`, `:dispatch` - the host's seams, each a value implementing
      core's protocol of that name, as `Wardrik.Host` lists them. One left
      out is that protocol's None: no grants, no credentials, and so on.
    * `:fleet` - the options of `Wardrik.Fleet.Supervisor`.
  """

  use Supervisor

  require Logger

  alias Wardrik.Agent
  alias Wardrik.Agent.Message
  alias Wardrik.Agent.Snapshot
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Audit
  alias Wardrik.Connections
  alias Wardrik.Connections.Connection
  alias Wardrik.Connections.Owner
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Deployment.Nodes
  alias Wardrik.Error
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Fleet
  alias Wardrik.Fleet.Member
  alias Wardrik.Forgetting
  alias Wardrik.Grant
  alias Wardrik.Host
  alias Wardrik.LLM.ToolRunner
  alias Wardrik.Moving
  alias Wardrik.Principal
  alias Wardrik.Servers
  alias Wardrik.Servers.Key
  alias Wardrik.Servers.Server
  alias Wardrik.Session
  alias Wardrik.Spawned
  alias Wardrik.Tokens
  alias Wardrik.Tokens.Token
  alias WardrikDefinition.Context

  @enforce_keys [:host]
  defstruct [:host, fleet: []]

  @type t() :: %__MODULE__{host: Wardrik.Host.t(), fleet: keyword()}

  @typedoc "A decision on a call an agent waits on."
  @type decision() :: :approve | {:approve, String.t()} | {:deny, String.t()}

  @typedoc "What became of an agent a forget reached: removed, kept with why, or not removed with why."
  @type outcome() :: :forgotten | {:kept, String.t()} | {:failed, String.t()}

  @seams [:grants, :credentials, :connections, :servers, :tokens, :triggers, :dispatch]

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
    opts = Keyword.validate!(opts, [:store, fleet: [], context: context([])] ++ @seams)
    store = Keyword.fetch!(opts, :store)

    host =
      Wardrik.Host.new(
        [
          store: store,
          definitions: %WardrikDefinition.Kept{store: store, contexts: opts[:context]},
          workspace: %WardrikWorkspace.Backend.Store{store: store}
        ] ++ Keyword.take(opts, @seams)
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
  The session `principal` acts in on `wardrik`'s agents: with the grants the
  host's `Wardrik.Grants` gives them, or with `:grant` alone.

      session = Wardrik.as(wardrik, maria)
  """
  @doc group: "Sessions"
  @spec as(t(), Principal.t() | nil, grant: Grant.t()) :: Session.t()
  def as(%__MODULE__{host: host}, principal, opts \\ []) do
    opts = Keyword.validate!(opts, [:grant])
    Session.new(host: host, principal: principal, grant: opts[:grant])
  end

  # -- talking to an agent ----------------------------------------------------

  @ask_opts NimbleOptions.new!(
              id: [
                type: {:or, [:string, nil]},
                doc: "the message's id, which the agent takes once; a new UUIDv7 by default"
              ]
            )

  @doc """
  Sends `agent` `text` from the session's principal, which it answers in a
  turn of its own. Acknowledged with the `Wardrik.Agent.Message` queued,
  whose `sequence` is where the agent's log stood: the turn that answers it
  is written after it, so `agent_stream/3` from there reads it. A session of
  an agent's own, as `Wardrik.Session.agent/1` makes, is answered back.

  ## Options

  #{NimbleOptions.docs(@ask_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_ask(Session.t(), AgentID.t(), String.t(), keyword()) ::
          {:ok, Message.t()} | {:error, Error.t()}
  def agent_ask(%Session{} = session, %AgentID{} = agent, text, opts \\ [])
      when is_binary(text) do
    opts = NimbleOptions.validate!(opts, @ask_opts)

    with :ok <- said(text, opts[:id]),
         {:ok, _caller} <- on_agent(session, agent, :message),
         {:ok, %Snapshot{sequence: sequence}} <- agent_snapshot(agent, session.host) do
      message =
        Message.new(text, opts[:id], sender: session.principal, reply_to: session.reply_to)

      message = %{message | sequence: sequence}

      case Agent.queue(agent, message, host: session.host) do
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
  `%Wardrik.Event.Log.Entry{}` messages, where the session may read it.
  """
  @doc group: "Talking to an agent"
  @spec agent_subscribe(Session.t(), AgentID.t()) :: :ok | {:error, Error.t()}
  def agent_subscribe(%Session{} = session, %AgentID{} = agent) do
    with {:ok, _caller} <- on_agent(session, agent, :read), do: Log.subscribe(agent)
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

      {:ok, message} = Wardrik.agent_ask(session, agent, "Summarise the inbox")
      {:ok, stream} = Wardrik.agent_stream(session, agent, after: message.sequence)

      Enum.find(stream, &(&1.event["type"] == "wardrik.run.completed"))

  ## Options

  #{NimbleOptions.docs(@stream_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_stream(Session.t(), AgentID.t(), keyword()) ::
          {:ok, Enumerable.t(Entry.t())} | {:error, Error.t()}
  def agent_stream(%Session{} = session, %AgentID{} = agent, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @stream_opts)

    with {:ok, _caller} <- on_agent(session, agent, :read),
         do: {:ok, Wardrik.Stream.new(Host.store(session.host), agent, opts[:after])}
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
  @spec agent_events(Session.t(), AgentID.t(), keyword()) ::
          {:ok, [Entry.t()]} | {:error, Error.t()}
  def agent_events(%Session{} = session, %AgentID{} = agent, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @page_opts)
    with {:ok, caller} <- on_agent(session, agent, :read), do: page(caller, agent, opts)
  end

  # A page of the log `log`, an agent's or the audit, as `opts` ask for it.
  defp page(caller, log, opts) do
    case Log.read(Host.store(caller.host), log, starting_after: opts[:after], limit: opts[:limit]) do
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
  @spec agent_approve(Session.t(), AgentID.t(), String.t() | [String.t()], keyword()) ::
          {:ok, %{String.t() => decision()}} | {:error, Error.t()}
  def agent_approve(%Session{} = session, %AgentID{} = agent, calls, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @approve_opts)
    decide(session, agent, calls, if(opts[:note], do: {:approve, opts[:note]}, else: :approve))
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
  @spec agent_deny(Session.t(), AgentID.t(), String.t() | [String.t()], keyword()) ::
          {:ok, %{String.t() => decision()}} | {:error, Error.t()}
  def agent_deny(%Session{} = session, %AgentID{} = agent, calls, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @deny_opts)
    decide(session, agent, calls, {:deny, opts[:reason]})
  end

  defp decide(session, agent, calls, decision),
    do: agent_decide(session, agent, Map.new(List.wrap(calls), &{&1, decision}))

  @doc """
  Decides several of the calls `agent` waits on at once, each by its id:
  `:approve`, `{:approve, note}` or `{:deny, reason}`, as `agent_approve/4`
  and `agent_deny/4` decide one kind. Acknowledged with the decisions taken;
  calls left out stay waiting.

  A session that may read the agent may ask; the agent takes the decisions
  from one whose grant allows `:decide` on it, or who asked for the turn
  that waits, and answers anyone else `:forbidden`.
  """
  @doc group: "Talking to an agent"
  @spec agent_decide(Session.t(), AgentID.t(), %{String.t() => decision()}) ::
          {:ok, %{String.t() => decision()}} | {:error, Error.t()}
  def agent_decide(%Session{} = session, %AgentID{} = agent, decisions) when is_map(decisions) do
    with {:ok, caller} <- on_agent(session, agent, :read) do
      case Agent.decide(agent, decisions, caller) do
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
      "This caller may not decide the calls of #{agent}, and did not ask for the turn that waits."
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
  event, so only a session that may decide the call reads it.
  """
  @doc group: "Talking to an agent"
  @spec agent_authorization_read(Session.t(), AgentID.t(), String.t()) ::
          {:ok, Wardrik.Call.Ask.link()} | {:error, Error.t()}
  def agent_authorization_read(%Session{} = session, %AgentID{} = agent, call) do
    with {:ok, _caller} <- on_agent(session, agent, :decide),
         {:ok, calls} <- parked(agent, session.host),
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
  @spec agent_read(Session.t(), AgentID.t()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def agent_read(%Session{} = session, %AgentID{} = agent) do
    with {:ok, _caller} <- on_agent(session, agent, :read),
         do: agent_snapshot(agent, session.host)
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
  @spec agent_clear(Session.t(), AgentID.t()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def agent_clear(%Session{} = session, %AgentID{} = agent) do
    with {:ok, caller} <- on_agent(session, agent, :message),
         :ok <- cleared(Agent.clear(agent, host: caller.host), agent) do
      audit(caller, [{:agent_cleared, agent}])
      agent_read(session, agent)
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

  @doc "Every agent under `prefix`, awake or asleep, as the fleet lists each, sorted by ID."
  @doc group: "Talking to an agent"
  @spec agents_list(Session.t(), Prefix.t()) :: {:ok, [Member.t()]} | {:error, Error.t()}
  def agents_list(%Session{} = session, prefix) do
    with {:ok, _caller} <- under(session, prefix, :read),
         do: {:ok, Fleet.list(prefix, host: session.host)}
  end

  @doc """
  Every call an agent under `prefix` waits on a person for, with the agent
  it is for, as `{id, {call, prompt}}`.
  """
  @doc group: "Talking to an agent"
  @spec agents_parked(Session.t(), Prefix.t()) ::
          {:ok, [{AgentID.t(), {Wardrik.Tool.call(), String.t()}}]} | {:error, Error.t()}
  def agents_parked(%Session{} = session, prefix) do
    with {:ok, _caller} <- under(session, prefix, :read) do
      {:ok,
       for(
         %Member{status: :parked, id: id} <- Fleet.list(prefix, host: session.host),
         {:ok, calls} <- [parked(id, session.host)],
         waiting <- calls,
         do: {id, waiting}
       )}
    end
  end

  # -- agent lifecycle ----------------------------------------------------------

  @doc """
  Defines `agent` with `definition`, or defines it again, and answers its
  snapshot. It runs under the session's grant's ceiling, ahead of its own
  hooks.
  """
  @doc group: "Agent lifecycle"
  @spec agent_define(Session.t(), AgentID.t(), map()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def agent_define(%Session{} = session, %AgentID{} = agent, definition)
      when is_map(definition) do
    with {:ok, caller} <- on_agent(session, agent, :define),
         {:ok, spec} <- defined(caller, agent, definition),
         {:ok, _pid} <-
           started(Fleet.put(%{spec | hooks: Grant.held(caller.grant, spec.hooks)}), agent) do
      audit(caller, [{:agent_defined, agent}])
      agent_snapshot(agent, caller.host)
    end
  end

  defp defined(caller, agent, fields) do
    case Definition.put(Host.definitions(caller.host), agent,
           definition: fields,
           grant: caller.grant
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
  @spec agent_definition_read(Session.t(), AgentID.t()) ::
          {:ok, Wardrik.Definition.Read.t()} | {:error, Error.t()}
  def agent_definition_read(%Session{} = session, %AgentID{} = agent) do
    with {:ok, caller} <- on_agent(session, agent, :read) do
      case Definition.get(Host.definitions(caller.host), agent) do
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
                  doc: "the node it starts on, which only a grant over every agent may choose"
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
  @spec agent_spawn(Session.t(), AgentID.t(), keyword()) ::
          {:ok, Spawned.t()} | {:error, Error.t()}
  def agent_spawn(%Session{} = session, %AgentID{} = agent, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @spawn_opts)

    with {:ok, caller} <- spawning(session, agent, opts[:node]),
         {from, spec} = from(caller, agent),
         {:ok, actions} <- spawn(caller, agent, {from, spec}, opts[:node]) do
      audit(caller, actions)
      {:ok, %Spawned{member: Fleet.lookup(agent, host: caller.host), from: from}}
    end
  end

  # Where an agent starts is the deployment's to say, so only a grant over
  # every agent names a node.
  defp spawning(session, agent, nil), do: on_agent(session, agent, :define)

  defp spawning(session, _agent, node) do
    with {:ok, caller} <- on_deployment(session, :define),
         :ok <- deployed(node),
         do: {:ok, caller}
  end

  defp deployed(node) do
    if node in Fleet.nodes(),
      do: :ok,
      else: {:error, Error.new(:invalid, "#{node} is not a node of this deployment.")}
  end

  defp from(caller, agent) do
    case {Fleet.lookup(agent, host: caller.host),
          Definition.current(Host.definitions(caller.host), agent)} do
      {%Member{asleep: false}, _current} -> {:running, nil}
      {_member, {:ok, spec}} -> {:definition, spec}
      {%Member{asleep: true}, :none} -> {:store, nil}
      {nil, :none} -> {:new, nil}
    end
  end

  # Starts the agent as it was found, on `node`, or wherever the fleet puts
  # it where `nil`: what the audit records of it.
  defp spawn(_caller, _agent, {:running, nil}, _node), do: {:ok, []}

  defp spawn(_caller, agent, {:store, nil}, node),
    do: agent |> Fleet.spawn(if(node, do: [node: node], else: [])) |> spawned(agent)

  defp spawn(_caller, agent, {:definition, spec}, node), do: spec |> put(node) |> spawned(agent)

  defp spawn(caller, agent, {:new, nil}, node) do
    case Definition.create(Host.definitions(caller.host), agent) do
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
  fleet lists it. What it is doing is interrupted. Only a grant over every
  agent may move one, since where an agent runs is the deployment's to say.
  """
  @doc group: "Agent lifecycle"
  @spec agent_move(Session.t(), AgentID.t(), node()) :: {:ok, Member.t()} | {:error, Error.t()}
  def agent_move(%Session{} = session, %AgentID{} = agent, node) when is_atom(node) do
    with {:ok, caller, moving} <- moving(session, agent, node),
         {:ok, actions} <- moved(moving) do
      audit(caller, actions)
      member(agent, session.host)
    end
  end

  @doc """
  What `agent_move/3` would do, checked as it checks: where the agent runs,
  where it goes, and what it is doing, which a move interrupts.
  """
  @doc group: "Agent lifecycle"
  @spec agent_move_preview(Session.t(), AgentID.t(), node()) ::
          {:ok, Moving.t()} | {:error, Error.t()}
  def agent_move_preview(%Session{} = session, %AgentID{} = agent, node) when is_atom(node) do
    with {:ok, _caller, moving} <- moving(session, agent, node), do: {:ok, moving}
  end

  defp moving(session, agent, node) do
    with {:ok, caller} <- on_deployment(session, :define),
         :ok <- deployed(node),
         {:ok, member} <- member(agent, session.host) do
      from = if member.asleep, do: :asleep, else: member.node
      {:ok, caller, %Moving{agent: agent, from: from, to: node, status: member.status}}
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
  @spec agent_cancel(Session.t(), AgentID.t()) :: :ok | {:error, Error.t()}
  def agent_cancel(%Session{} = session, %AgentID{} = agent) do
    with {:ok, caller} <- on_agent(session, agent, :message),
         {:ok, member} <- member(agent, session.host),
         do: audit(caller, for(id <- cancelled([member]), do: {:agent_cancelled, id}))
  end

  @doc "Ends the turn of every agent under `prefix`, and answers those it ended."
  @doc group: "Agent lifecycle"
  @spec agents_cancel(Session.t(), Prefix.t()) :: {:ok, [AgentID.t()]} | {:error, Error.t()}
  def agents_cancel(%Session{} = session, prefix) do
    with {:ok, caller} <- under(session, prefix, :message) do
      cancelled = cancelled(Fleet.list(prefix, host: session.host))
      audit(caller, for(id <- cancelled, do: {:agent_cancelled, id, prefix}))
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
  @spec agent_stop(Session.t(), AgentID.t()) :: {:ok, Member.t()} | {:error, Error.t()}
  def agent_stop(%Session{} = session, %AgentID{} = agent) do
    with {:ok, caller} <- on_agent(session, agent, :define),
         {:ok, member} <- member(agent, session.host) do
      :ok = stopped(caller, member)
      member(agent, session.host)
    end
  end

  # One asleep already has nothing to stop, and nothing is recorded; nor for
  # one that went to sleep since it was looked up.
  defp stopped(_caller, %Member{asleep: true}), do: :ok

  defp stopped(caller, %Member{id: agent}) do
    case Fleet.stop(agent) do
      :ok -> audit(caller, [{:agent_stopped, agent}])
      {:error, :noproc} -> :ok
    end
  end

  @doc """
  Removes `agent`, with everything it had, and the definition the host
  keeps of it, which may refuse. It is forgotten where it is kept, awake or
  asleep, or a definition of it is.
  """
  @doc group: "Agent lifecycle"
  @spec agent_forget(Session.t(), AgentID.t()) :: :ok | {:error, Error.t()}
  def agent_forget(%Session{} = session, %AgentID{} = agent) do
    with {:ok, caller, _forgetting} <- forgetting(session, agent) do
      case Definitions.forget(caller.host, agent) do
        {:ok, kept} -> forgotten(caller, agent, kept)
        {:error, :conflict, why} -> {:error, Error.new(:conflict, why)}
      end
    end
  end

  defp forgotten(caller, agent, kept) do
    stored = Fleet.stored?(agent)
    if stored, do: :ok = Fleet.forget(agent)

    if stored or kept,
      do: audit(caller, [{:agent_forgotten, agent}]),
      else: {:error, Error.no_agent(agent)}
  end

  @doc "What `agent_forget/2` would do, checked as it checks."
  @doc group: "Agent lifecycle"
  @spec agent_forget_preview(Session.t(), AgentID.t()) ::
          {:ok, Forgetting.t()} | {:error, Error.t()}
  def agent_forget_preview(%Session{} = session, %AgentID{} = agent) do
    with {:ok, _caller, forgetting} <- forgetting(session, agent), do: {:ok, forgetting}
  end

  defp forgetting(session, agent) do
    with {:ok, caller} <- on_agent(session, agent, :define),
         :ok <- kept(caller.host, agent) do
      case Definition.editable(Host.definitions(caller.host), agent) do
        :ok -> {:ok, caller, %Forgetting{agents: [agent], kept: []}}
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
  Removes every agent under `prefix` but those the host keeps, and answers
  what became of each. A prefix with nothing under it is not found, and one
  whose every agent is kept is a conflict saying why.
  """
  @doc group: "Agent lifecycle"
  @spec agents_forget(Session.t(), Prefix.t()) ::
          {:ok, %{AgentID.t() => outcome()}} | {:error, Error.t()}
  def agents_forget(%Session{} = session, prefix) do
    with {:ok, caller, %Forgetting{agents: agents, kept: kept}} <-
           forgetting_under(session, prefix) do
      outcomes = Map.new(agents, &{&1, forget(caller.host, &1)})
      audit(caller, for({id, :forgotten} <- outcomes, do: {:agent_forgotten, id, prefix}))
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
  @spec agents_forget_preview(Session.t(), Prefix.t()) ::
          {:ok, Forgetting.t()} | {:error, Error.t()}
  def agents_forget_preview(%Session{} = session, prefix) do
    with {:ok, _caller, forgetting} <- forgetting_under(session, prefix), do: {:ok, forgetting}
  end

  defp forgetting_under(session, prefix) do
    with {:ok, caller} <- under(session, prefix, :define) do
      definitions = Host.definitions(caller.host)

      checked =
        for %Member{id: id} <- Fleet.list(prefix, host: caller.host),
            do: {id, Definition.editable(definitions, id)}

      case {for({id, :ok} <- checked, do: id),
            for({id, {:error, :conflict, why}} <- checked, do: {id, why})} do
        {[], []} -> {:error, Error.new(:not_found, "Nothing runs under #{prefix}.")}
        {[], kept} -> {:error, Error.new(:conflict, Enum.map_join(kept, "\n", &elem(&1, 1)))}
        {agents, kept} -> {:ok, caller, %Forgetting{agents: agents, kept: kept}}
      end
    end
  end

  @doc """
  The tool calls `agent` is running now, each with its id, the tool's name,
  and how long it has run. An agent asleep runs none, and is not found.
  """
  @doc group: "Agent lifecycle"
  @spec agent_calls(Session.t(), AgentID.t()) ::
          {:ok, [%{call_id: String.t(), name: String.t(), elapsed_ms: non_neg_integer()}]}
          | {:error, Error.t()}
  def agent_calls(%Session{} = session, %AgentID{} = agent) do
    with {:ok, _caller} <- on_agent(session, agent, :read),
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
  @spec agent_call_kill(Session.t(), AgentID.t(), String.t()) :: :ok | {:error, Error.t()}
  def agent_call_kill(%Session{} = session, %AgentID{} = agent, call_id)
      when is_binary(call_id) do
    with {:ok, caller} <- on_agent(session, agent, :message),
         {:ok, node} <- awake(agent) do
      case :erpc.call(node, ToolRunner, :kill_call, [agent, call_id]) do
        :ok ->
          audit(caller, [{:call_killed, agent, call_id}])

        {:error, :not_found} ->
          {:error, Error.new(:not_found, "#{agent} is not running #{call_id}.")}
      end
    end
  end

  # The node `agent` runs on, whose tool runner holds its calls.
  defp awake(agent) do
    case Fleet.whereis(agent, wake: false) do
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
  @spec agent_trigger_set(Session.t(), AgentID.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def agent_trigger_set(%Session{} = session, %AgentID{} = agent, name, fields)
      when is_binary(name) and is_map(fields) do
    with {:ok, caller} <- on_agent(session, agent, :define),
         {:ok, trigger} <- trigger_set(caller, agent, name, fields),
         do: audited(caller, [{:trigger_set, agent, name}], trigger)
  end

  defp trigger_set(caller, agent, name, fields) do
    case Definition.put_trigger(Host.definitions(caller.host), agent, name, fields: fields) do
      {:ok, _created_or_changed, trigger} -> {:ok, trigger}
      {:error, :not_found} -> {:error, undefined(agent)}
      :unsupported -> {:error, Error.new(:unsupported, "This server keeps no triggers.")}
      refused -> refused(refused)
    end
  end

  @doc "Removes `agent`'s trigger `name`, and answers it as `agent_trigger_set/4` would."
  @doc group: "Triggers"
  @spec agent_trigger_remove(Session.t(), AgentID.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def agent_trigger_remove(%Session{} = session, %AgentID{} = agent, name) when is_binary(name) do
    with {:ok, caller} <- on_agent(session, agent, :define),
         {:ok, trigger} <- trigger_removed(caller, agent, name),
         do: audited(caller, [{:trigger_removed, agent, name}], trigger)
  end

  defp trigger_removed(caller, agent, name) do
    case Definition.delete_trigger(Host.definitions(caller.host), agent, name) do
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

  The session must be able to message the agent, so a surface that takes
  such requests from anyone grants just that, on just that agent; the
  trigger decides whether the request is the sender's. One that is not is
  answered as one to no such trigger, so a request tells its sender nothing
  of the triggers another org's agents have.
  """
  @doc group: "Triggers"
  @spec agent_trigger_deliver(Session.t(), AgentID.t(), String.t(), %{
          headers: [{String.t(), String.t()}],
          body: binary()
        }) :: {:ok, atom()} | {:error, Error.t()}
  def agent_trigger_deliver(
        %Session{} = session,
        %AgentID{} = agent,
        trigger,
        %{headers: headers, body: body}
      ) do
    with {:ok, caller} <- on_agent(session, agent, :message) do
      request = %{headers: headers, body: body}

      case Wardrik.Triggers.deliver(Host.triggers(caller.host), agent, trigger, request: request) do
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

  @doc "The MCP servers `owner`, a person's or an org's agents, added."
  @doc group: "Servers and connections"
  @spec servers_list(Session.t(), Prefix.t()) :: {:ok, [Server.t()]} | {:error, Error.t()}
  def servers_list(%Session{} = session, owner) do
    with {:ok, caller} <- under(session, owner, :read), do: servers(caller, owner)
  end

  defp servers(caller, owner) do
    case Servers.list(Host.servers(caller.host), owner) do
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
  @spec servers_add(Session.t(), Prefix.t(), Server.t()) ::
          {:ok, Server.t()} | {:error, Error.t()}
  def servers_add(%Session{} = session, owner, %Server{} = server) do
    with {:ok, caller} <- under(session, owner, :define) do
      case Servers.add(Host.servers(caller.host), owner,
             name: server.name,
             fields: fields(server),
             by: caller.principal
           ) do
        {:ok, added} ->
          audited(caller, [{:server_added, Key.new(owner, server.name), server.url}], %{
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
  @spec servers_remove(Session.t(), Prefix.t(), String.t()) ::
          {:ok, Server.t()} | {:error, Error.t()}
  def servers_remove(%Session{} = session, owner, name) when is_binary(name) do
    with {:ok, caller} <- under(session, owner, :define),
         {:ok, servers} <- servers(caller, owner),
         :ok <- Servers.remove(Host.servers(caller.host), owner, name: name, by: caller.principal) do
      audited(
        caller,
        [{:server_removed, Key.new(owner, name)}],
        Enum.find(servers, &(&1.name == name))
      )
    end
  end

  @doc "The accounts the deployment offers `owner`, and who holds each; never a value."
  @doc group: "Servers and connections"
  @spec connections_list(Session.t(), Prefix.t()) :: {:ok, [Connection.t()]} | {:error, Error.t()}
  def connections_list(%Session{} = session, owner) do
    with {:ok, caller} <- under(session, owner, :read), do: connections(caller, owner)
  end

  defp connections(caller, owner) do
    case Connections.list(Host.connections(caller.host), Owner.owner_of(owner)) do
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
  @spec connections_connect(Session.t(), Prefix.t(), String.t()) ::
          {:ok, Connection.t()} | {:error, Error.t()}
  def connections_connect(%Session{} = session, owner, provider)
      when is_binary(provider) do
    with {:ok, caller} <- under(session, owner, :define),
         {:ok, link} <- connect(caller, owner, provider),
         {:ok, connections} <- connections(caller, owner) do
      {:ok, %{Enum.find(connections, &(&1.provider == provider)) | authorization: link}}
    end
  end

  defp connect(caller, owner, provider) do
    connections = Host.connections(caller.host)

    case Connections.connect(connections, provider, Owner.owner_of(owner), by: caller.principal) do
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
  @spec connections_disconnect(Session.t(), Prefix.t(), String.t()) ::
          {:ok, Connection.t()} | {:error, Error.t()}
  def connections_disconnect(%Session{} = session, owner, provider)
      when is_binary(provider) do
    with {:ok, caller} <- under(session, owner, :define) do
      whose = Owner.owner_of(owner)

      case Connections.disconnect(Host.connections(caller.host), provider, whose) do
        :ok ->
          audited(caller, [{:secret_removed, provider, owner}], %Connection{
            provider: provider,
            held_by: held_by(whose)
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

  # An owner forgets only an account of their own.
  defp held_by({_org, _user}), do: :person
  defp held_by(_org), do: :org

  # -- tokens -----------------------------------------------------------------------

  @doc "Every token the host keeps, oldest first; never a secret."
  @doc group: "Tokens"
  @spec tokens_list(Session.t()) :: {:ok, [Token.t()]} | {:error, Error.t()}
  def tokens_list(%Session{} = session) do
    with {:ok, caller} <- on_deployment(session, :read), do: tokens(caller)
  end

  defp tokens(caller) do
    case Tokens.list(Host.tokens(caller.host)) do
      :unsupported -> {:error, Wardrik.Tokens.None.unsupported()}
      tokens -> {:ok, tokens}
    end
  end

  @create_token_opts NimbleOptions.new!(
                       for: [
                         type: {:struct, Principal},
                         doc: "the person it acts for; itself where left out"
                       ]
                     )

  @doc """
  Makes a token named `name` carrying `grant`, and answers it with its
  secret, given this once; the audit records the token, never the secret.
  A token for a person whose scope names another person's agents,
  `acme/@maria/` for `jon`, is refused: it would act as one on what is the
  other's.

  ## Options

  #{NimbleOptions.docs(@create_token_opts)}
  """
  @doc group: "Tokens"
  @spec tokens_create(Session.t(), String.t(), Grant.t(), keyword()) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def tokens_create(%Session{} = session, name, %Grant{} = grant, opts \\ [])
      when is_binary(name) do
    opts = NimbleOptions.validate!(opts, @create_token_opts)

    with {:ok, caller} <- on_deployment(session, :define),
         :ok <- issued(grant, opts[:for]) do
      case Tokens.create(Host.tokens(caller.host), name, grant: grant, for: opts[:for]) do
        {:ok, token} ->
          audited(
            caller,
            [{:token_created, token.id, token.name, token.grant, token.principal}],
            token
          )

        {:error, message} ->
          {:error, Error.new(:invalid, message)}

        :unsupported ->
          {:error, Wardrik.Tokens.None.unsupported()}
      end
    end
  end

  defp issued(_grant, nil), do: :ok

  defp issued(grant, for) do
    case Prefix.user(grant.scope) do
      nil ->
        :ok

      user ->
        if user == Principal.id(for),
          do: :ok,
          else:
            {:error,
             Error.new(
               :invalid,
               "A token for #{Principal.id(for)} cannot reach #{grant.scope}, which is #{user}'s."
             )}
    end
  end

  @doc """
  Stops the token `id` working, ends what is open on it, and answers it,
  without its secret.
  """
  @doc group: "Tokens"
  @spec tokens_revoke(Session.t(), String.t()) :: {:ok, Token.t()} | {:error, Error.t()}
  def tokens_revoke(%Session{} = session, id) when is_binary(id) do
    with {:ok, caller} <- on_deployment(session, :define),
         {:ok, tokens} <- tokens(caller),
         {:ok, token} <- token(tokens, id) do
      case Tokens.revoke(Host.tokens(caller.host), id) do
        :ok -> audited(caller, [{:token_revoked, id}], token)
        {:error, :not_found} -> token([], id)
      end
    end
  end

  defp token(tokens, id) do
    case Enum.find(tokens, &(&1.id == id)) do
      nil -> {:error, Error.new(:not_found, "No token has the id #{id}.")}
      token -> {:ok, token}
    end
  end

  # -- the deployment ---------------------------------------------------------------

  @doc "The deployment's nodes, each with how many agents run on it, and how many sleep."
  @doc group: "Deployment"
  @spec deployment_nodes(Session.t()) :: {:ok, Nodes.t()} | {:error, Error.t()}
  def deployment_nodes(%Session{} = session) do
    with {:ok, _caller} <- on_deployment(session, :read) do
      {asleep, running} =
        Enum.split_with(Fleet.list(Prefix.all(), host: session.host), & &1.asleep)

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
  @spec deployment_reload(Session.t()) :: {:ok, [node()]} | {:error, Error.t()}
  def deployment_reload(%Session{} = session) do
    with {:ok, caller} <- on_deployment(session, :define) do
      definitions = Host.definitions(caller.host)

      case Definition.reloading(definitions) do
        [] ->
          {:error, Error.new(:unsupported, "This deployment reads no definitions again.")}

        nodes ->
          :ok = Definitions.reload_on(definitions, nodes)
          audited(caller, [{:agents_reloaded, nodes}], nodes)
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
  @spec deployment_audit(Session.t(), keyword()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def deployment_audit(%Session{} = session, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @page_opts)
    with {:ok, caller} <- on_deployment(session, :read), do: page(caller, :audit, opts)
  end

  # -- checking and recording -------------------------------------------------------

  # The caller `session` is to `agent`, where its grant allows `action` on it.
  defp on_agent(session, agent, action) do
    with {:ok, caller} <- Session.caller(session, agent),
         :ok <- Grant.authorize(caller.grant, action, agent),
         do: {:ok, caller}
  end

  defp under(session, prefix, action) do
    with {:ok, caller} <- Session.caller(session, prefix),
         :ok <- Grant.authorize_under(caller.grant, action, prefix),
         do: {:ok, caller}
  end

  # The deployment is acted on by a grant over every agent alone, so a
  # caller held to an org or a person never learns, nor changes, where any
  # agent runs.
  defp on_deployment(session, action) do
    case under(session, Prefix.all(), action) do
      {:ok, caller} ->
        {:ok, caller}

      {:error, _error} ->
        {:error, Error.new(:forbidden, "This caller may not act on the deployment.")}
    end
  end

  # Records `actions`, one change, as the caller's.
  defp audit(caller, actions),
    do: Audit.record_all(Host.audit(caller.host), actions, by: caller.principal)

  defp audited(caller, actions, answer) do
    :ok = audit(caller, actions)
    {:ok, answer}
  end

  # -- raising --------------------------------------------------------------------

  @doc "As `agent_ask/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_ask!(Session.t(), AgentID.t(), String.t(), keyword()) :: Message.t()
  def agent_ask!(session, agent, text, opts \\ []),
    do: unwrap(agent_ask(session, agent, text, opts))

  @doc "As `agent_subscribe/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_subscribe!(Session.t(), AgentID.t()) :: :ok
  def agent_subscribe!(session, agent), do: unwrap(agent_subscribe(session, agent))

  @doc "As `agent_stream/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_stream!(Session.t(), AgentID.t(), keyword()) :: Enumerable.t(Entry.t())
  def agent_stream!(session, agent, opts \\ []), do: unwrap(agent_stream(session, agent, opts))

  @doc "As `agent_events/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_events!(Session.t(), AgentID.t(), keyword()) :: [Entry.t()]
  def agent_events!(session, agent, opts \\ []), do: unwrap(agent_events(session, agent, opts))

  @doc "As `agent_approve/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_approve!(Session.t(), AgentID.t(), String.t() | [String.t()], keyword()) :: %{
          String.t() => decision()
        }
  def agent_approve!(session, agent, calls, opts \\ []),
    do: unwrap(agent_approve(session, agent, calls, opts))

  @doc "As `agent_deny/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_deny!(Session.t(), AgentID.t(), String.t() | [String.t()], keyword()) :: %{
          String.t() => decision()
        }
  def agent_deny!(session, agent, calls, opts \\ []),
    do: unwrap(agent_deny(session, agent, calls, opts))

  @doc "As `agent_decide/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_decide!(Session.t(), AgentID.t(), %{String.t() => decision()}) ::
          %{String.t() => decision()}
  def agent_decide!(session, agent, decisions),
    do: unwrap(agent_decide(session, agent, decisions))

  @doc "As `agent_authorization_read/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_authorization_read!(Session.t(), AgentID.t(), String.t()) :: Wardrik.Call.Ask.link()
  def agent_authorization_read!(session, agent, call),
    do: unwrap(agent_authorization_read(session, agent, call))

  @doc "As `agent_read/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_read!(Session.t(), AgentID.t()) :: Snapshot.t()
  def agent_read!(session, agent), do: unwrap(agent_read(session, agent))

  @doc "As `agent_clear/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_clear!(Session.t(), AgentID.t()) :: Snapshot.t()
  def agent_clear!(session, agent), do: unwrap(agent_clear(session, agent))

  @doc "As `agents_list/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agents_list!(Session.t(), Prefix.t()) :: [Member.t()]
  def agents_list!(session, prefix), do: unwrap(agents_list(session, prefix))

  @doc "As `agents_parked/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agents_parked!(Session.t(), Prefix.t()) :: [
          {AgentID.t(), {Wardrik.Tool.call(), String.t()}}
        ]
  def agents_parked!(session, prefix), do: unwrap(agents_parked(session, prefix))

  @doc "As `agent_define/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_define!(Session.t(), AgentID.t(), map()) :: Snapshot.t()
  def agent_define!(session, agent, definition),
    do: unwrap(agent_define(session, agent, definition))

  @doc "As `agent_definition_read/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_definition_read!(Session.t(), AgentID.t()) :: Wardrik.Definition.Read.t()
  def agent_definition_read!(session, agent), do: unwrap(agent_definition_read(session, agent))

  @doc "As `agent_spawn/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_spawn!(Session.t(), AgentID.t(), keyword()) :: Spawned.t()
  def agent_spawn!(session, agent, opts \\ []), do: unwrap(agent_spawn(session, agent, opts))

  @doc "As `agent_move/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_move!(Session.t(), AgentID.t(), node()) :: Member.t()
  def agent_move!(session, agent, node), do: unwrap(agent_move(session, agent, node))

  @doc "As `agent_move_preview/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_move_preview!(Session.t(), AgentID.t(), node()) :: Moving.t()
  def agent_move_preview!(session, agent, node),
    do: unwrap(agent_move_preview(session, agent, node))

  @doc "As `agent_cancel/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_cancel!(Session.t(), AgentID.t()) :: :ok
  def agent_cancel!(session, agent), do: unwrap(agent_cancel(session, agent))

  @doc "As `agents_cancel/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agents_cancel!(Session.t(), Prefix.t()) :: [AgentID.t()]
  def agents_cancel!(session, prefix), do: unwrap(agents_cancel(session, prefix))

  @doc "As `agent_stop/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_stop!(Session.t(), AgentID.t()) :: Member.t()
  def agent_stop!(session, agent), do: unwrap(agent_stop(session, agent))

  @doc "As `agent_forget/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_forget!(Session.t(), AgentID.t()) :: :ok
  def agent_forget!(session, agent), do: unwrap(agent_forget(session, agent))

  @doc "As `agents_forget/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agents_forget!(Session.t(), Prefix.t()) :: %{AgentID.t() => outcome()}
  def agents_forget!(session, prefix), do: unwrap(agents_forget(session, prefix))

  @doc "As `agent_forget_preview/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_forget_preview!(Session.t(), AgentID.t()) :: Forgetting.t()
  def agent_forget_preview!(session, agent), do: unwrap(agent_forget_preview(session, agent))

  @doc "As `agents_forget_preview/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agents_forget_preview!(Session.t(), Prefix.t()) :: Forgetting.t()
  def agents_forget_preview!(session, prefix),
    do: unwrap(agents_forget_preview(session, prefix))

  @doc "As `agent_calls/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_calls!(Session.t(), AgentID.t()) :: [
          %{call_id: String.t(), name: String.t(), elapsed_ms: non_neg_integer()}
        ]
  def agent_calls!(session, agent), do: unwrap(agent_calls(session, agent))

  @doc "As `agent_call_kill/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_call_kill!(Session.t(), AgentID.t(), String.t()) :: :ok
  def agent_call_kill!(session, agent, call_id),
    do: unwrap(agent_call_kill(session, agent, call_id))

  @doc "As `agent_trigger_set/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Triggers"
  @spec agent_trigger_set!(Session.t(), AgentID.t(), String.t(), map()) :: map()
  def agent_trigger_set!(session, agent, name, fields),
    do: unwrap(agent_trigger_set(session, agent, name, fields))

  @doc "As `agent_trigger_remove/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Triggers"
  @spec agent_trigger_remove!(Session.t(), AgentID.t(), String.t()) :: map()
  def agent_trigger_remove!(session, agent, name),
    do: unwrap(agent_trigger_remove(session, agent, name))

  @doc "As `agent_trigger_deliver/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Triggers"
  @spec agent_trigger_deliver!(Session.t(), AgentID.t(), String.t(), map()) :: atom()
  def agent_trigger_deliver!(session, agent, trigger, request),
    do: unwrap(agent_trigger_deliver(session, agent, trigger, request))

  @doc "As `servers_list/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec servers_list!(Session.t(), Prefix.t()) :: [Server.t()]
  def servers_list!(session, owner), do: unwrap(servers_list(session, owner))

  @doc "As `servers_add/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec servers_add!(Session.t(), Prefix.t(), Server.t()) :: Server.t()
  def servers_add!(session, owner, server), do: unwrap(servers_add(session, owner, server))

  @doc "As `servers_remove/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec servers_remove!(Session.t(), Prefix.t(), String.t()) :: Server.t()
  def servers_remove!(session, owner, name), do: unwrap(servers_remove(session, owner, name))

  @doc "As `connections_list/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec connections_list!(Session.t(), Prefix.t()) :: [Connection.t()]
  def connections_list!(session, owner), do: unwrap(connections_list(session, owner))

  @doc "As `connections_connect/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec connections_connect!(Session.t(), Prefix.t(), String.t()) :: Connection.t()
  def connections_connect!(session, owner, provider),
    do: unwrap(connections_connect(session, owner, provider))

  @doc "As `connections_disconnect/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Servers and connections"
  @spec connections_disconnect!(Session.t(), Prefix.t(), String.t()) :: Connection.t()
  def connections_disconnect!(session, owner, provider),
    do: unwrap(connections_disconnect(session, owner, provider))

  @doc "As `tokens_list/1`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Tokens"
  @spec tokens_list!(Session.t()) :: [Token.t()]
  def tokens_list!(session), do: unwrap(tokens_list(session))

  @doc "As `tokens_create/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Tokens"
  @spec tokens_create!(Session.t(), String.t(), Grant.t(), keyword()) :: Token.t()
  def tokens_create!(session, name, grant, opts \\ []),
    do: unwrap(tokens_create(session, name, grant, opts))

  @doc "As `tokens_revoke/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Tokens"
  @spec tokens_revoke!(Session.t(), String.t()) :: Token.t()
  def tokens_revoke!(session, id), do: unwrap(tokens_revoke(session, id))

  @doc "As `deployment_nodes/1`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Deployment"
  @spec deployment_nodes!(Session.t()) :: Nodes.t()
  def deployment_nodes!(session), do: unwrap(deployment_nodes(session))

  @doc "As `deployment_reload/1`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Deployment"
  @spec deployment_reload!(Session.t()) :: [node()]
  def deployment_reload!(session), do: unwrap(deployment_reload(session))

  @doc "As `deployment_audit/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Deployment"
  @spec deployment_audit!(Session.t(), keyword()) :: [Entry.t()]
  def deployment_audit!(session, opts \\ []), do: unwrap(deployment_audit(session, opts))

  defp unwrap({:ok, value}), do: value
  defp unwrap(:ok), do: :ok
  defp unwrap({:error, error}), do: raise(error)
end
