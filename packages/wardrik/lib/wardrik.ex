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

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias Wardrik.Command
  alias Wardrik.Connections.Connection
  alias Wardrik.Error
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Host
  alias Wardrik.Operations
  alias Wardrik.Operations.Ask
  alias Wardrik.Principal
  alias Wardrik.Query
  alias Wardrik.Servers.Server
  alias Wardrik.Session
  alias Wardrik.Tokens.Token
  alias WardrikDefinition.Context

  @enforce_keys [:host]
  defstruct [:host, fleet: []]

  @type t() :: %__MODULE__{host: Wardrik.Host.t(), fleet: keyword()}

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
      {WardrikTrigger, store: store}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  The session `principal` acts in on `wardrik`'s agents: with the grants the
  host's `Wardrik.Grants` gives them, or with `:grant` alone.

      session = Wardrik.as(wardrik, maria)
  """
  @doc group: "Sessions"
  @spec as(t(), Principal.t() | nil, grant: Wardrik.Grant.t()) :: Session.t()
  def as(%__MODULE__{host: host}, principal, opts \\ []) do
    opts = Keyword.validate!(opts, [:grant])
    Session.new(host: host, principal: principal, grant: opts[:grant])
  end

  # -- talking to an agent ----------------------------------------------------

  @ask_opts NimbleOptions.new!(
              id: [
                type: :string,
                doc: "the message's id, which the agent takes once; a new UUIDv7 by default"
              ]
            )

  @doc """
  Sends `agent` `text` from the session's principal, which it answers in a
  turn of its own. Acknowledged with the `Wardrik.Agent.Message` queued,
  whose `sequence` is where the agent's log stood: the turn that answers it
  is written after it, so `agent_stream/3` from there reads it.

  ## Options

  #{NimbleOptions.docs(@ask_opts)}
  """
  @doc group: "Talking to an agent"
  @spec agent_ask(Session.t(), AgentID.t(), String.t(), keyword()) ::
          {:ok, Wardrik.Agent.Message.t()} | {:error, Error.t()}
  def agent_ask(%Session{} = session, %AgentID{} = agent, text, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @ask_opts)
    message = Map.reject(%{"content" => text, "id" => opts[:id]}, &is_nil(elem(&1, 1)))

    with {:ok, request} <- Ask.new(agent, message), do: change(session, request)
  end

  @doc """
  Sends this process every entry `agent`'s log writes from now on, as
  `%Wardrik.Event.Log.Entry{}` messages, where the session may read it.
  """
  @doc group: "Talking to an agent"
  @spec agent_subscribe(Session.t(), AgentID.t()) :: :ok | {:error, Error.t()}
  def agent_subscribe(%Session{} = session, %AgentID{} = agent) do
    with :ok <- readable(session, agent), do: Log.subscribe(agent)
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

    with :ok <- readable(session, agent),
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

    read(session, %Operations.ReadEvents{
      agent: agent,
      starting_after: opts[:after],
      limit: opts[:limit]
    })
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
          {:ok, %{String.t() => Operations.Decide.decision()}} | {:error, Error.t()}
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
          {:ok, %{String.t() => Operations.Decide.decision()}} | {:error, Error.t()}
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
  """
  @doc group: "Talking to an agent"
  @spec agent_decide(Session.t(), AgentID.t(), %{String.t() => Operations.Decide.decision()}) ::
          {:ok, %{String.t() => Operations.Decide.decision()}} | {:error, Error.t()}
  def agent_decide(%Session{} = session, %AgentID{} = agent, decisions) when is_map(decisions),
    do: change(session, %Operations.Decide{agent: agent, decisions: decisions})

  @doc """
  Where a person authorizes the call `call` that `agent` waits on: the page,
  and the code to enter where one is needed.
  """
  @doc group: "Talking to an agent"
  @spec agent_authorization_read(Session.t(), AgentID.t(), String.t()) ::
          {:ok, Wardrik.Call.Ask.link()} | {:error, Error.t()}
  def agent_authorization_read(%Session{} = session, %AgentID{} = agent, call),
    do: read(session, %Operations.ReadAuthorization{agent: agent, interrupt: call})

  @doc "`agent`'s snapshot: what it is doing, what it waits on, and its conversation."
  @doc group: "Talking to an agent"
  @spec agent_read(Session.t(), AgentID.t()) ::
          {:ok, Wardrik.Agent.Snapshot.t()} | {:error, Error.t()}
  def agent_read(%Session{} = session, %AgentID{} = agent),
    do: read(session, %Operations.ReadAgent{agent: agent})

  @doc "Empties `agent`'s conversation, and the labels of what it read, and answers its snapshot."
  @doc group: "Talking to an agent"
  @spec agent_clear(Session.t(), AgentID.t()) ::
          {:ok, Wardrik.Agent.Snapshot.t()} | {:error, Error.t()}
  def agent_clear(%Session{} = session, %AgentID{} = agent) do
    with {:ok, nil} <- change(session, %Operations.Clear{agent: agent}),
         do: agent_read(session, agent)
  end

  @doc "Every agent under `prefix`, awake or asleep, as the fleet lists each."
  @doc group: "Talking to an agent"
  @spec agents_list(Session.t(), Prefix.t()) ::
          {:ok, [Wardrik.Fleet.Member.t()]} | {:error, Error.t()}
  def agents_list(%Session{} = session, %Prefix{} = prefix),
    do: read(session, %Operations.ListAgents{prefix: prefix})

  @doc """
  Every call an agent under `prefix` waits on a person for, with the agent
  it is for, as `{id, {call, prompt}}`.
  """
  @doc group: "Talking to an agent"
  @spec agents_parked(Session.t(), Prefix.t()) ::
          {:ok, [{AgentID.t(), {Wardrik.Tool.call(), String.t()}}]} | {:error, Error.t()}
  def agents_parked(%Session{} = session, %Prefix{} = prefix),
    do: read(session, %Operations.ListParked{prefix: prefix})

  # -- agent lifecycle ----------------------------------------------------------

  @doc """
  Defines `agent` with `definition`, or defines it again, and answers its
  snapshot. It runs under the session's grant's ceiling, ahead of its own
  hooks.
  """
  @doc group: "Agent lifecycle"
  @spec agent_define(Session.t(), AgentID.t(), map()) ::
          {:ok, Wardrik.Agent.Snapshot.t()} | {:error, Error.t()}
  def agent_define(%Session{} = session, %AgentID{} = agent, definition) when is_map(definition),
    do: change(session, %Operations.Define{agent: agent, definition: definition})

  @doc "`agent`'s definition as it was last put, and the tools it names that offer nothing yet."
  @doc group: "Agent lifecycle"
  @spec agent_definition_read(Session.t(), AgentID.t()) ::
          {:ok, Wardrik.Definition.Read.t()} | {:error, Error.t()}
  def agent_definition_read(%Session{} = session, %AgentID{} = agent),
    do: read(session, %Operations.ReadDefinition{agent: agent})

  @spawn_opts NimbleOptions.new!(
                node: [
                  type: :atom,
                  doc: "the node it starts on, which only a grant over every agent may choose"
                ]
              )

  @doc """
  Starts `agent` and answers it as the fleet lists it: one asleep wakes, one
  the host defines starts on its definition, and one running already runs on.

  ## Options

  #{NimbleOptions.docs(@spawn_opts)}
  """
  @doc group: "Agent lifecycle"
  @spec agent_spawn(Session.t(), AgentID.t(), keyword()) ::
          {:ok, Wardrik.Fleet.Member.t()} | {:error, Error.t()}
  def agent_spawn(%Session{} = session, %AgentID{} = agent, opts \\ []) do
    opts = NimbleOptions.validate!(opts, @spawn_opts)

    case opts[:node] do
      nil -> change(session, %Operations.Spawn{agent: agent})
      node -> change(session, %Operations.SpawnOn{agent: agent, node: node})
    end
  end

  @doc """
  Starts `agent` again on `node`, with what it had, and answers it as the
  fleet lists it. Only a grant over every agent may move one.
  """
  @doc group: "Agent lifecycle"
  @spec agent_move(Session.t(), AgentID.t(), node()) ::
          {:ok, Wardrik.Fleet.Member.t()} | {:error, Error.t()}
  def agent_move(%Session{} = session, %AgentID{} = agent, node) when is_atom(node),
    do: change(session, %Operations.Move{agent: agent, node: node})

  @doc "Ends the turn `agent` is taking, and what is queued behind it. It keeps running."
  @doc group: "Agent lifecycle"
  @spec agent_cancel(Session.t(), AgentID.t()) :: :ok | {:error, Error.t()}
  def agent_cancel(%Session{} = session, %AgentID{} = agent),
    do: session |> change(%Operations.Cancel{agent: agent}) |> acknowledged()

  @doc "Ends the turn of every agent under `prefix`, and answers those it ended."
  @doc group: "Agent lifecycle"
  @spec agents_cancel(Session.t(), Prefix.t()) :: {:ok, [AgentID.t()]} | {:error, Error.t()}
  def agents_cancel(%Session{} = session, %Prefix{} = prefix),
    do: change(session, %Operations.CancelAgents{prefix: prefix})

  @doc """
  Stops `agent` now, keeping its conversation, and answers it as the fleet
  lists it, asleep: it wakes when something asks it.
  """
  @doc group: "Agent lifecycle"
  @spec agent_stop(Session.t(), AgentID.t()) ::
          {:ok, Wardrik.Fleet.Member.t()} | {:error, Error.t()}
  def agent_stop(%Session{} = session, %AgentID{} = agent) do
    with {:ok, _stopped} <- change(session, %Operations.Stop{agent: agent}) do
      case Wardrik.Fleet.lookup(agent) do
        nil -> {:error, Wardrik.AgentOperation.not_found(agent)}
        member -> {:ok, member}
      end
    end
  end

  @doc "Removes `agent`, with everything it had, and the definition the host keeps of it."
  @doc group: "Agent lifecycle"
  @spec agent_forget(Session.t(), AgentID.t()) :: :ok | {:error, Error.t()}
  def agent_forget(%Session{} = session, %AgentID{} = agent),
    do: session |> change(%Operations.Forget{agent: agent}) |> acknowledged()

  @doc """
  Removes every agent under `prefix` but those the host keeps, and answers
  what became of each: `:forgotten`, `{:kept, why}` or `{:failed, why}`.
  """
  @doc group: "Agent lifecycle"
  @spec agents_forget(Session.t(), Prefix.t()) ::
          {:ok, %{AgentID.t() => Operations.Forgetting.outcome()}} | {:error, Error.t()}
  def agents_forget(%Session{} = session, %Prefix{} = prefix),
    do: change(session, %Operations.ForgetAgents{prefix: prefix})

  # -- triggers -------------------------------------------------------------------

  @doc """
  Sets `agent`'s trigger `name` to `fields`, as `wardrik_protocol`'s
  `trigger_definition.json` describes one, and answers the trigger.
  """
  @doc group: "Triggers"
  @spec agent_trigger_set(Session.t(), AgentID.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def agent_trigger_set(%Session{} = session, %AgentID{} = agent, name, fields)
      when is_binary(name) and is_map(fields),
      do: change(session, %Operations.SetTrigger{agent: agent, name: name, fields: fields})

  @doc "Removes `agent`'s trigger `name`, and answers it as `agent_trigger_set/4` would."
  @doc group: "Triggers"
  @spec agent_trigger_remove(Session.t(), AgentID.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def agent_trigger_remove(%Session{} = session, %AgentID{} = agent, name) when is_binary(name),
    do: change(session, %Operations.RemoveTrigger{agent: agent, name: name})

  @doc """
  Hands `agent`'s trigger `trigger` a request from outside, its `:headers`
  and `:body`, which the trigger checks. Acknowledged with `:asked`, or
  `:seen` where it was handed the same request before.
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
      ),
      do:
        change(session, %Operations.Deliver{
          agent: agent,
          trigger: trigger,
          headers: headers,
          body: body
        })

  # -- servers and connections ------------------------------------------------------

  @doc "The MCP servers `owner`, a person's or an org's agents, added."
  @doc group: "Servers and connections"
  @spec servers_list(Session.t(), Prefix.t()) :: {:ok, [Server.t()]} | {:error, Error.t()}
  def servers_list(%Session{} = session, %Prefix{} = owner),
    do: read(session, %Operations.ReadServers{owner: owner})

  @doc """
  Adds `server` for `owner`'s agents, by its name, URL, how they sign in to
  it and which of its tools they take, and answers it, with where someone
  signs in to it first where they have to.
  """
  @doc group: "Servers and connections"
  @spec servers_add(Session.t(), Prefix.t(), Server.t()) ::
          {:ok, Server.t()} | {:error, Error.t()}
  def servers_add(%Session{} = session, %Prefix{} = owner, %Server{} = server) do
    how =
      case server.auth do
        "secret" -> given(name: server.secret, header: server.header, scheme: server.scheme)
        "oauth" -> given(scopes: server.scopes)
        _none -> %{}
      end

    fields =
      Map.merge(
        %{"url" => server.url, "auth" => %{server.auth => how}},
        given(only: server.only, except: server.except)
      )

    change(session, %Operations.AddServer{owner: owner, name: server.name, fields: fields})
  end

  # The fields of `pairs` that are given, by their names as text.
  defp given(pairs),
    do: for({key, value} <- pairs, value != nil, into: %{}, do: {"#{key}", value})

  @doc "Removes the MCP server `name` `owner` added, and answers it."
  @doc group: "Servers and connections"
  @spec servers_remove(Session.t(), Prefix.t(), String.t()) ::
          {:ok, Server.t()} | {:error, Error.t()}
  def servers_remove(%Session{} = session, %Prefix{} = owner, name) when is_binary(name),
    do: change(session, %Operations.RemoveServer{owner: owner, name: name})

  @doc "The accounts the deployment offers `owner`, and who holds each."
  @doc group: "Servers and connections"
  @spec connections_list(Session.t(), Prefix.t()) :: {:ok, [Connection.t()]} | {:error, Error.t()}
  def connections_list(%Session{} = session, %Prefix{} = owner),
    do: read(session, %Operations.ReadConnections{owner: owner})

  @doc """
  Connects `owner`'s account at `provider` before any agent asks for it, and
  answers the connection, with where to authorize it where it is not held.
  """
  @doc group: "Servers and connections"
  @spec connections_connect(Session.t(), Prefix.t(), String.t()) ::
          {:ok, Connection.t()} | {:error, Error.t()}
  def connections_connect(%Session{} = session, %Prefix{} = owner, provider)
      when is_binary(provider),
      do: change(session, %Operations.Connect{owner: owner, provider: provider})

  @doc "Forgets `owner`'s account at `provider`, and answers the connection as it was."
  @doc group: "Servers and connections"
  @spec connections_disconnect(Session.t(), Prefix.t(), String.t()) ::
          {:ok, Connection.t()} | {:error, Error.t()}
  def connections_disconnect(%Session{} = session, %Prefix{} = owner, provider)
      when is_binary(provider),
      do: change(session, %Operations.Disconnect{owner: owner, provider: provider})

  # -- tokens -----------------------------------------------------------------------

  @doc "Every token the host keeps, oldest first; never a secret."
  @doc group: "Tokens"
  @spec tokens_list(Session.t()) :: {:ok, [Token.t()]} | {:error, Error.t()}
  def tokens_list(%Session{} = session), do: read(session, %Operations.ListTokens{})

  @create_token_opts NimbleOptions.new!(
                       for: [
                         type: {:struct, Principal},
                         doc: "the person it acts for; itself where left out"
                       ]
                     )

  @doc """
  Makes a token named `name` carrying `grant`, and answers it with its
  secret, given this once.

  ## Options

  #{NimbleOptions.docs(@create_token_opts)}
  """
  @doc group: "Tokens"
  @spec tokens_create(Session.t(), String.t(), Wardrik.Grant.t(), keyword()) ::
          {:ok, Token.t()} | {:error, Error.t()}
  def tokens_create(%Session{} = session, name, %Wardrik.Grant{} = grant, opts \\ [])
      when is_binary(name) do
    opts = NimbleOptions.validate!(opts, @create_token_opts)
    change(session, %Operations.CreateToken{name: name, grant: grant, for: opts[:for]})
  end

  @doc "Stops the token `id` working, and answers it, without its secret."
  @doc group: "Tokens"
  @spec tokens_revoke(Session.t(), String.t()) :: {:ok, Token.t()} | {:error, Error.t()}
  def tokens_revoke(%Session{} = session, id) when is_binary(id),
    do: change(session, %Operations.RevokeToken{id: id})

  # -- the deployment ---------------------------------------------------------------

  @doc "The deployment's nodes, each with how many agents run on it, and how many sleep."
  @doc group: "Deployment"
  @spec deployment_nodes(Session.t()) :: {:ok, Wardrik.Deployment.Nodes.t()} | {:error, Error.t()}
  def deployment_nodes(%Session{} = session), do: read(session, %Operations.ReadNodes{})

  @doc "Has every node read its agents' definitions again, and answers those that did."
  @doc group: "Deployment"
  @spec deployment_reload(Session.t()) :: {:ok, [node()]} | {:error, Error.t()}
  def deployment_reload(%Session{} = session), do: change(session, %Operations.Reload{})

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
    read(session, %Operations.ReadAudit{starting_after: opts[:after], limit: opts[:limit]})
  end

  # -- running operations -----------------------------------------------------------

  defp read(session, %module{} = request) do
    with {:ok, caller} <- Session.caller(session, module.subject(request)),
         do: Query.run(request, caller)
  end

  defp change(session, %module{} = request) do
    with {:ok, caller} <- Session.caller(session, module.subject(request)),
         {made, answer} when made in [:ok, :created] <- Command.run(request, caller),
         do: {:ok, answer}
  end

  defp acknowledged({:ok, _answer}), do: :ok
  defp acknowledged({:error, _error} = error), do: error

  defp readable(session, agent) do
    with {:ok, caller} <- Session.caller(session, agent),
         do: Wardrik.Subject.authorize(agent, caller.grant, :read)
  end

  # -- raising --------------------------------------------------------------------

  @doc "As `agent_ask/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_ask!(Session.t(), AgentID.t(), String.t(), keyword()) :: Wardrik.Agent.Message.t()
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
          String.t() => Operations.Decide.decision()
        }
  def agent_approve!(session, agent, calls, opts \\ []),
    do: unwrap(agent_approve(session, agent, calls, opts))

  @doc "As `agent_deny/4`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_deny!(Session.t(), AgentID.t(), String.t() | [String.t()], keyword()) :: %{
          String.t() => Operations.Decide.decision()
        }
  def agent_deny!(session, agent, calls, opts \\ []),
    do: unwrap(agent_deny(session, agent, calls, opts))

  @doc "As `agent_decide/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_decide!(Session.t(), AgentID.t(), %{String.t() => Operations.Decide.decision()}) ::
          %{String.t() => Operations.Decide.decision()}
  def agent_decide!(session, agent, decisions),
    do: unwrap(agent_decide(session, agent, decisions))

  @doc "As `agent_authorization_read/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_authorization_read!(Session.t(), AgentID.t(), String.t()) :: Wardrik.Call.Ask.link()
  def agent_authorization_read!(session, agent, call),
    do: unwrap(agent_authorization_read(session, agent, call))

  @doc "As `agent_read/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_read!(Session.t(), AgentID.t()) :: Wardrik.Agent.Snapshot.t()
  def agent_read!(session, agent), do: unwrap(agent_read(session, agent))

  @doc "As `agent_clear/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agent_clear!(Session.t(), AgentID.t()) :: Wardrik.Agent.Snapshot.t()
  def agent_clear!(session, agent), do: unwrap(agent_clear(session, agent))

  @doc "As `agents_list/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agents_list!(Session.t(), Prefix.t()) :: [Wardrik.Fleet.Member.t()]
  def agents_list!(session, prefix), do: unwrap(agents_list(session, prefix))

  @doc "As `agents_parked/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Talking to an agent"
  @spec agents_parked!(Session.t(), Prefix.t()) :: [
          {AgentID.t(), {Wardrik.Tool.call(), String.t()}}
        ]
  def agents_parked!(session, prefix), do: unwrap(agents_parked(session, prefix))

  @doc "As `agent_define/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_define!(Session.t(), AgentID.t(), map()) :: Wardrik.Agent.Snapshot.t()
  def agent_define!(session, agent, definition),
    do: unwrap(agent_define(session, agent, definition))

  @doc "As `agent_definition_read/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_definition_read!(Session.t(), AgentID.t()) :: Wardrik.Definition.Read.t()
  def agent_definition_read!(session, agent), do: unwrap(agent_definition_read(session, agent))

  @doc "As `agent_spawn/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_spawn!(Session.t(), AgentID.t(), keyword()) :: Wardrik.Fleet.Member.t()
  def agent_spawn!(session, agent, opts \\ []), do: unwrap(agent_spawn(session, agent, opts))

  @doc "As `agent_move/3`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_move!(Session.t(), AgentID.t(), node()) :: Wardrik.Fleet.Member.t()
  def agent_move!(session, agent, node), do: unwrap(agent_move(session, agent, node))

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
  @spec agent_stop!(Session.t(), AgentID.t()) :: Wardrik.Fleet.Member.t()
  def agent_stop!(session, agent), do: unwrap(agent_stop(session, agent))

  @doc "As `agent_forget/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agent_forget!(Session.t(), AgentID.t()) :: :ok
  def agent_forget!(session, agent), do: unwrap(agent_forget(session, agent))

  @doc "As `agents_forget/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Agent lifecycle"
  @spec agents_forget!(Session.t(), Prefix.t()) :: %{
          AgentID.t() => Operations.Forgetting.outcome()
        }
  def agents_forget!(session, prefix), do: unwrap(agents_forget(session, prefix))

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
  @spec tokens_create!(Session.t(), String.t(), Wardrik.Grant.t(), keyword()) :: Token.t()
  def tokens_create!(session, name, grant, opts \\ []),
    do: unwrap(tokens_create(session, name, grant, opts))

  @doc "As `tokens_revoke/2`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Tokens"
  @spec tokens_revoke!(Session.t(), String.t()) :: Token.t()
  def tokens_revoke!(session, id), do: unwrap(tokens_revoke(session, id))

  @doc "As `deployment_nodes/1`, answering the value, or raising the `Wardrik.Error`."
  @doc group: "Deployment"
  @spec deployment_nodes!(Session.t()) :: Wardrik.Deployment.Nodes.t()
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
