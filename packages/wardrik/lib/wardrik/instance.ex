defmodule Wardrik.Instance do
  @moduledoc false
  # What `use Wardrik` runs: the config an instance reads, the host it
  # builds once as it starts and keeps in `:persistent_term`, and what each
  # of its functions does with the user it is called as.

  use Supervisor

  alias Wardrik.AgentAddress
  alias Wardrik.AgentID
  alias Wardrik.AgentID.Segment
  alias Wardrik.Error
  alias Wardrik.Host
  alias Wardrik.Principal
  alias Wardrik.Resource
  alias Wardrik.Scope
  alias Wardrik.Servers.Server
  alias Wardrik.Thread
  alias Wardrik.Token

  @schema NimbleOptions.new!(
            store: [
              type: {:or, [{:in, [:memory]}, :keyword_list]},
              required: true,
              doc:
                "where everything is kept: `[repo: MyApp.Repo]`, `[bucket: \"name\", ...]` or " <>
                  "`[data_dir: path]`, as `Wardrik.store/1` reads them, or `:memory` for tests"
            ],
            tools: [
              type: {:list, :atom},
              default: [],
              doc: "your own tools, each a module that uses `Wardrik.Tool`"
            ],
            policies: [
              type: {:or, [{:map, {:or, [:atom, :string]}, :any}, :keyword_list]},
              default: %{},
              doc: "the policies a definition may name, by name"
            ],
            held: [
              type: {:list, {:or, [:string, :atom]}},
              default: [],
              doc:
                "the names of the policies every agent is held to, ahead of its own, such as " <>
                  "each org's budget"
            ],
            defaults: [
              type: {:or, [{:map, {:or, [:atom, :string]}, :any}, :keyword_list]},
              default: %{},
              doc:
                "what an agent gets where its definition says nothing: `idle_timeout`, " <>
                  "`retries`, and the definition of one started without any"
            ],
            vault: [
              type: :keyword_list,
              keys: [
                keys: [
                  type: {:list, :string},
                  required: true,
                  doc:
                    "base64 keys, the first of which seals; make one with `WardrikVault.generate_key/0`"
                ]
              ],
              doc: "keeps people's credentials in the store, sealed"
            ],
            plugins: [
              type: {:list, {:or, [:atom, {:tuple, [:atom, :keyword_list]}]}},
              default: [],
              doc:
                "packages that add to Wardrik, each a module or `{module, opts}`, in order; see `Wardrik.Plugin`"
            ],
            expires: [
              type: :keyword_list,
              keys: [
                session: [
                  type: :pos_integer,
                  doc: "a user's token, in seconds; 12 hours by default"
                ],
                api: [type: :pos_integer, doc: "an API token, in seconds; 90 days by default"]
              ],
              doc: "how long tokens last"
            ]
          )

  @only NimbleOptions.new!(
          only: [
            type: {:in, [:own, :org]},
            doc: "the user's own agents, or their org's; both by default"
          ]
        )

  @org NimbleOptions.new!(
         org: [type: :boolean, default: false, doc: "their org's, not their own"]
       )

  @following [
    types: [type: {:list, :string}, doc: "the event types to take; every type by default"]
  ]

  @subscribe NimbleOptions.new!(@following)

  @id [type: {:or, [:string, nil]}, doc: "the message's id; a new one by default"]
  @timeout [
    type: :timeout,
    default: 60_000,
    doc: "how long to wait, in milliseconds, or `:infinity`"
  ]

  @send NimbleOptions.new!(id: @id)
  @ask NimbleOptions.new!(id: @id, timeout: @timeout)

  @events NimbleOptions.new!(
            @following ++
              [
                after: [
                  type: {:or, [:string, {:in, [:head]}]},
                  doc: "the cursor to read after, or `:head` for what is written from now"
                ],
                follow: [
                  type: :boolean,
                  doc: "whether to go on taking events as they are written"
                ]
              ]
          )

  # The instance's functions, by the parameters each takes, `{name, default}`
  # for one with a default.
  @functions [
    define: [:user, :agent, :fields, {:opts, []}],
    definition: [:user, :agent],
    get: [:user, :agent],
    list: [:user, {:opts, []}],
    start: [:user, :agent],
    stop: [:user, :agent],
    clear: [:user, :agent],
    forget: [:user, :agent],
    put_trigger: [:user, :agent, :name, :fields],
    delete_trigger: [:user, :agent, :name],
    ask: [:user, :agent, :text, {:opts, []}],
    send: [:user, :agent, :text, {:opts, []}],
    await: [:user, :sent, {:opts, []}],
    approve: [:user, :agent, :calls, {:opts, []}],
    deny: [:user, :agent, :calls, {:opts, []}],
    decide: [:user, :agent, :decisions],
    waiting: [:user, {:opts, []}],
    authorization: [:user, :agent, :call],
    cancel: [:user, :agent],
    calls: [:user, :agent],
    kill_call: [:user, :agent, :call],
    subscribe: [:user, :agent, {:opts, []}],
    unsubscribe: [:user, :agent],
    events: [:user, :agent, {:opts, []}],
    servers: [:user, {:opts, []}],
    add_server: [:user, :server, {:opts, []}],
    remove_server: [:user, :name, {:opts, []}],
    connections: [:user],
    connect: [:user, :provider],
    disconnect: [:user, :provider],
    reload: [],
    nodes: [],
    audit: [{:opts, []}],
    move: [:agent, :node]
  ]

  @doc false
  def schema, do: @schema

  # What `use Wardrik` defines of each function: one calling this module's
  # of its name with the instance first, and, but for `unsubscribe`, which
  # answers `:ok` alone, a bang answering the value or raising the error.
  @doc false
  def functions do
    for {name, params} <- @functions do
      head = Enum.map(params, &param/1)
      args = Enum.map(params, &arg/1)

      quote do
        def unquote(name)(unquote_splicing(head)),
          do: Wardrik.Instance.unquote(name)(__MODULE__, unquote_splicing(args))

        unquote(bang(name, head, args))
      end
    end
  end

  defp bang(:unsubscribe, _head, _args), do: nil

  defp bang(name, head, args) do
    quote do
      @doc "As `#{unquote(name)}/#{unquote(length(args))}`, answering the value or raising the `Wardrik.Error`."
      def unquote(:"#{name}!")(unquote_splicing(head)),
        do: Wardrik.Instance.unwrap(unquote(name)(unquote_splicing(args)))
    end
  end

  defp param({name, default}), do: quote(do: unquote(Macro.var(name, nil)) \\ unquote(default))
  defp param(name), do: Macro.var(name, nil)

  defp arg({name, _default}), do: Macro.var(name, nil)
  defp arg(name), do: Macro.var(name, nil)

  @doc false
  def options(:only), do: NimbleOptions.docs(@only)
  def options(:org), do: NimbleOptions.docs(@org)
  def options(:subscribe), do: NimbleOptions.docs(@subscribe)
  def options(:events), do: NimbleOptions.docs(@events)

  # -- starting -------------------------------------------------------------------

  @doc false
  def config(module, otp_app, opts) do
    otp_app
    |> Application.get_env(module, [])
    |> Keyword.merge(opts)
    |> NimbleOptions.validate!(@schema)
  end

  @doc false
  def start_link(module, otp_app, opts) do
    config = config(module, otp_app, opts)
    :ok = alone!(module)
    host = build(module, config)
    put(module, host)
    Supervisor.start_link(__MODULE__, host, name: module)
  end

  @impl true
  def init(%Host{} = host),
    do:
      Supervisor.init([{WardrikStore, Host.store(host)}, {Wardrik, host}],
        strategy: :rest_for_one
      )

  # A node runs one Wardrik, since core registers its processes by name.
  defp alone!(module) do
    if Process.whereis(Wardrik.Core),
      do:
        raise(ArgumentError, "#{inspect(module)} can't start: #{running()}, and a node runs one")

    :ok
  end

  defp running do
    case for {{__MODULE__, instance}, %Host{}} <- :persistent_term.get(),
             Process.whereis(instance),
             do: instance do
      [instance | _others] -> "#{inspect(instance)} already runs Wardrik on this node"
      [] -> "Wardrik already runs on this node, started without `use Wardrik`"
    end
  end

  @doc false
  def build(module, config) do
    store = Wardrik.store(config[:store])

    context =
      Wardrik.context(
        policies: policies(config[:policies]),
        held: Enum.map(config[:held], &to_string/1),
        defaults: fields(config[:defaults])
      )

    [
      store: store,
      issuer: %Wardrik.Instance.Issuer{module: module},
      tools: config[:tools],
      context: context
    ]
    |> Kernel.++(vault(config[:vault], store))
    |> Kernel.++(Keyword.take(config, [:expires]))
    |> Wardrik.new()
    |> Host.register(:settings, [{__MODULE__, module: module}])
    |> plugins(config[:plugins])
  end

  defp policies(policies),
    do:
      Map.new(fields(policies), fn {name, policy} ->
        {name, WardrikPolicy.decode!(policy, name)}
      end)

  defp vault(nil, _store), do: []
  defp vault(vault, store), do: [credentials: WardrikVault.new(store: store, keys: vault[:keys])]

  defp plugins(host, plugins), do: Enum.reduce(plugins, host, &plugin/2)

  defp plugin({module, opts}, host) do
    Code.ensure_loaded!(module)

    unless function_exported?(module, :attach, 2),
      do: raise(ArgumentError, "#{inspect(module)} is not a plugin: it has no attach/2")

    :ok = validated(module, opts)
    module.attach(host, opts)
  end

  defp plugin(module, host), do: plugin({module, []}, host)

  defp validated(module, opts) do
    if function_exported?(module, :validate, 1),
      do: valid(module, opts, module.validate(opts)),
      else: :ok
  end

  defp valid(_module, _opts, :ok), do: :ok

  # Not the options themselves, which may hold a secret.
  defp valid(module, _opts, {:error, message}),
    do: raise(ArgumentError, "#{inspect(module)}'s options in plugins: #{message}")

  @doc false
  def put(module, %Host{} = host), do: :persistent_term.put({__MODULE__, module}, host)

  @doc false
  def host(module) do
    case :persistent_term.get({__MODULE__, module}, nil) do
      nil ->
        raise ArgumentError, "#{inspect(module)} isn't started: add it to your supervision tree"

      host ->
        host
    end
  end

  # The instance a plugin's host belongs to, or nil for one built without
  # `use Wardrik`.
  @doc false
  def of(%Host{} = host), do: Host.settings(host, __MODULE__)[:module]

  # -- acting ---------------------------------------------------------------------

  # The scope `user` acts in, for what acts on the instance's behalf, such
  # as a request to its HTTP API.
  @doc false
  def as(module, user) do
    {scope, _who} = scope(module, user)
    scope
  end

  # The scope `user` acts in on `module`'s agents, and the org and id they
  # are known by there.
  defp scope(module, user) do
    {principal, who} = principal(module, user)
    {Wardrik.as(host(module), principal), who}
  end

  defp principal(module, user) do
    case module.principal(user) do
      %{org: org, id: id} = answered ->
        who = %{org: segment(org), id: segment(id)}

        unless AgentID.org?(who.org) and AgentID.segment?(who.id),
          do: raise(ArgumentError, unnamed(module, answered))

        {Principal.new("#{who.org}/@#{who.id}", name: Map.get(answered, :name)), who}

      answered ->
        raise ArgumentError, unnamed(module, answered)
    end
  end

  defp segment(value), do: Segment.to_segment(value)

  defp unnamed(module, answered) do
    "#{inspect(module)}.principal/1 answered #{inspect(answered)}; it answers %{org: org, id: id}, " <>
      "and a :name where you have one, each of org and id holding no /, whitespace, *, ? or :, " <>
      "nor beginning with @ or _"
  end

  defp on(module, user, agent, fun) do
    {scope, who} = scope(module, user)
    with {:ok, agent} <- agent(who, agent), do: fun.(scope, agent)
  end

  defp agent(%{org: org, id: id}, name) when is_binary(name),
    do: id(AgentID.new(name, org: org, user: id))

  defp agent(%{org: org}, {:org, name}) when is_binary(name), do: id(AgentID.new(name, org: org))
  defp agent(_who, %AgentID{} = agent), do: {:ok, agent}
  defp agent(_who, %Thread{} = thread), do: {:ok, thread}

  defp id({:ok, id}), do: {:ok, id}
  defp id({:error, message}), do: {:error, Error.new(:invalid, message)}

  # What `fun` answers for the user's own agents and their org's, joined, or
  # for the one `:only` names. One the user reaches nothing of adds nothing,
  # unless it is all they asked for.
  defp under(module, user, opts, fun) do
    opts = NimbleOptions.validate!(opts, @only)
    {scope, who} = scope(module, user)

    answered =
      for only <- List.wrap(opts[:only] || [:own, :org]), do: fun.(scope, agents(who, only))

    case for {:ok, found} <- answered, do: found do
      [] -> hd(answered)
      found -> {:ok, Enum.concat(found)}
    end
  end

  defp agents(%{org: org, id: id}, :own), do: Resource.parse!("#{org}/@#{id}/agent/*")
  defp agents(%{org: org}, :org), do: Resource.parse!("#{org}/agent/*")

  defp owner(%{org: org}, true), do: Resource.parse!(org)
  defp owner(%{org: org, id: id}, false), do: Resource.parse!("#{org}/@#{id}")

  # The agents `agent` names to follow: one, or every agent the user reads.
  defp following(module, user, :all, fun) do
    {scope, _who} = scope(module, user)
    fun.(scope, [])
  end

  defp following(module, user, agent, fun),
    do: on(module, user, agent, &fun.(&1, resources: [AgentAddress.resource(&2)]))

  # Your app itself, acting on everything: what no user calls.
  defp app(module), do: Scope.new(host(module), Token.root(Principal.deployment()))

  # A definition, a trigger or a policy as Wardrik reads one: string keys,
  # from a keyword list or a map, all the way down.
  @doc false
  def fields(fields) when is_map(fields),
    do: Map.new(fields, fn {key, value} -> {to_string(key), value(value)} end)

  def fields(fields) when is_list(fields), do: fields |> Map.new() |> fields()

  defp value(%_{} = struct), do: struct
  defp value(map) when is_map(map), do: fields(map)

  defp value([{key, _value} | _rest] = list) when is_atom(key) do
    if Keyword.keyword?(list), do: fields(list), else: Enum.map(list, &value/1)
  end

  defp value(list) when is_list(list), do: Enum.map(list, &value/1)
  defp value(value), do: value

  # -- the functions ---------------------------------------------------------------

  @doc false
  def define(module, user, agent, fields, opts),
    do: on(module, user, agent, &Wardrik.agent_define(&1, &2, fields(fields), opts))

  @doc false
  def definition(module, user, agent),
    do: on(module, user, agent, &Wardrik.agent_definition_read/2)

  @doc false
  def get(module, user, agent), do: on(module, user, agent, &Wardrik.agent_read/2)

  @doc false
  def list(module, user, opts), do: under(module, user, opts, &Wardrik.agents_list/2)

  @doc false
  def ask(module, user, agent, text, opts) do
    opts = NimbleOptions.validate!(opts, @ask)

    with {:ok, message} <- send(module, user, agent, text, Keyword.take(opts, [:id])),
         do: await(module, user, message, Keyword.take(opts, [:timeout]))
  end

  @doc false
  def send(module, user, agent, text, opts) do
    opts = NimbleOptions.validate!(opts, @send)
    on(module, user, agent, &Wardrik.agent_ask(&1, &2, text, opts))
  end

  @doc false
  def await(module, user, sent, opts) do
    {scope, _who} = scope(module, user)
    Wardrik.agent_await(scope, sent, opts)
  end

  @doc false
  def approve(module, user, agent, calls, opts),
    do: on(module, user, agent, &Wardrik.agent_approve(&1, &2, calls, opts))

  @doc false
  def deny(module, user, agent, calls, opts),
    do: on(module, user, agent, &Wardrik.agent_deny(&1, &2, calls, opts))

  @doc false
  def decide(module, user, agent, decisions),
    do: on(module, user, agent, &Wardrik.agent_decide(&1, &2, decisions))

  @doc false
  def waiting(module, user, opts), do: under(module, user, opts, &Wardrik.agents_parked/2)

  @doc false
  def authorization(module, user, agent, call),
    do: on(module, user, agent, &Wardrik.agent_authorization_read(&1, &2, call))

  @doc false
  def start(module, user, agent), do: on(module, user, agent, &Wardrik.agent_spawn/2)

  @doc false
  def stop(module, user, agent), do: on(module, user, agent, &Wardrik.agent_stop/2)

  @doc false
  def cancel(module, user, agent), do: on(module, user, agent, &Wardrik.agent_cancel/2)

  @doc false
  def clear(module, user, agent), do: on(module, user, agent, &Wardrik.agent_clear/2)

  @doc false
  def forget(module, user, agent), do: on(module, user, agent, &Wardrik.agent_forget/2)

  @doc false
  def calls(module, user, agent), do: on(module, user, agent, &Wardrik.agent_calls/2)

  @doc false
  def kill_call(module, user, agent, call),
    do: on(module, user, agent, &Wardrik.agent_call_kill(&1, &2, call))

  @doc false
  def put_trigger(module, user, agent, name, fields),
    do:
      on(module, user, agent, &Wardrik.agent_trigger_set(&1, &2, to_string(name), fields(fields)))

  @doc false
  def delete_trigger(module, user, agent, name),
    do: on(module, user, agent, &Wardrik.agent_trigger_remove(&1, &2, to_string(name)))

  @doc false
  def subscribe(module, user, agent, opts) do
    opts = NimbleOptions.validate!(opts, @subscribe)
    following(module, user, agent, &Wardrik.subscribe(&1, &2 ++ opts))
  end

  @doc false
  def unsubscribe(module, user, agent), do: following(module, user, agent, &Wardrik.unsubscribe/2)

  @doc false
  def events(module, user, agent, opts) do
    opts = NimbleOptions.validate!(opts, @events)
    following(module, user, agent, &Wardrik.events(&1, &2 ++ opts))
  end

  @doc false
  def servers(module, user, opts) do
    opts = NimbleOptions.validate!(opts, @org)
    {scope, who} = scope(module, user)
    Wardrik.servers_list(scope, owner(who, opts[:org]))
  end

  @doc false
  def add_server(module, user, server, opts) do
    opts = NimbleOptions.validate!(opts, @org)
    {scope, who} = scope(module, user)
    Wardrik.servers_add(scope, owner(who, opts[:org]), server(server))
  end

  defp server(%Server{} = server), do: server
  defp server(fields), do: struct!(Server, fields)

  @doc false
  def remove_server(module, user, name, opts) do
    opts = NimbleOptions.validate!(opts, @org)
    {scope, who} = scope(module, user)
    Wardrik.servers_remove(scope, owner(who, opts[:org]), to_string(name))
  end

  @doc false
  def connections(module, user) do
    {scope, who} = scope(module, user)
    Wardrik.connections_list(scope, owner(who, false))
  end

  @doc false
  def connect(module, user, provider) do
    {scope, who} = scope(module, user)
    Wardrik.connections_connect(scope, owner(who, false), to_string(provider))
  end

  @doc false
  def disconnect(module, user, provider) do
    {scope, who} = scope(module, user)
    Wardrik.connections_disconnect(scope, owner(who, false), to_string(provider))
  end

  @doc false
  def reload(module), do: Wardrik.deployment_reload(app(module))

  @doc false
  def nodes(module), do: Wardrik.deployment_nodes(app(module))

  @doc false
  def audit(module, opts), do: Wardrik.deployment_audit(app(module), opts)

  @doc false
  def move(module, agent, node) do
    with {:ok, agent} <- address(agent), do: Wardrik.agent_move(app(module), agent, node)
  end

  defp address(%AgentID{} = agent), do: {:ok, agent}
  defp address(%Thread{} = thread), do: {:ok, thread}
  defp address(text) when is_binary(text), do: id(AgentID.address(text))

  @doc false
  def unwrap({:ok, value}), do: value
  def unwrap({:waiting, waiting}), do: waiting
  def unwrap(:ok), do: :ok
  def unwrap({:error, error}), do: raise(error)
end
