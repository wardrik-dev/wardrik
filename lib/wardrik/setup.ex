defmodule Wardrik.Setup do
  @moduledoc "Builds `%Wardrik{}` from `Wardrik.start_link/1`'s options, and each agent's options."

  @oauth NimbleOptions.new!(
           page: [
             type: :string,
             required: true,
             doc: "Where sign-ins come back to, as `\"https://agents.example.com/oauth\"`."
           ],
           providers: [
             type: {:list, {:tuple, [{:or, [:atom, :string]}, :keyword_list]}},
             default: [],
             doc: "Providers to start with, by name. See `WardrikOAuth.Provider`."
           ],
           client_name: [
             type: :string,
             doc: "The name a service shows for a client Wardrik registers."
           ],
           req_options: [
             type: :keyword_list,
             default: [],
             doc: "Extra options for every `Req` request."
           ]
         )

  @doc """
  The `:oauth` option of `Wardrik.start_link/1`.

  #{NimbleOptions.docs(@oauth)}
  """
  @spec oauth_schema() :: NimbleOptions.t()
  def oauth_schema, do: @oauth

  @doc "Builds a `%Wardrik{}` from `Wardrik.start_link/1`'s options."
  @spec wardrik(keyword()) :: Wardrik.t()
  def wardrik(opts) do
    opts =
      Keyword.validate!(opts, [
        :name,
        :store,
        :backend,
        :policy,
        :oauth,
        :mcp,
        :declarations,
        :workspace,
        :notify,
        :orgs,
        :discovery_interval_ms,
        defaults: %{},
        listeners: [],
        channels: [],
        triggers: [],
        keys: [],
        deployment: "local",
        authorizer: {Wardrik.Statements, []},
        retention: 30,
        capabilities: [],
        policies: [],
        middleware: [],
        idle_timeout: 900,
        trusted_workers: false,
        egress: &Wardrik.Egress.public/1,
        prices: %{}
      ])

    name = Keyword.fetch!(opts, :name)
    store = store(name, opts[:store])

    %Wardrik{
      name: name,
      store: store,
      keys: opts[:keys],
      oauth: oauth(opts[:oauth], opts[:keys]),
      mcp: opts[:mcp],
      listeners: opts[:listeners],
      channels: Map.new(opts[:channels], fn {name, entry} -> {to_string(name), entry} end),
      notify: Wardrik.Notify.settings(opts[:notify]),
      declarations: opts[:declarations],
      orgs: opts[:orgs],
      workspace: Wardrik.Workspaces.settings(opts[:workspace]),
      defaults: Wardrik.Type.json(opts[:defaults]),
      triggers: Keyword.validate!(opts[:triggers], [:req_options, :reconcile]),
      deployment: opts[:deployment],
      authorizer: opts[:authorizer],
      retention: opts[:retention],
      backend: opts[:backend] || backend(store, opts[:discovery_interval_ms]),
      policy: policy(opts[:policy]),
      capabilities:
        Map.new(opts[:capabilities], fn {name, entry} -> {to_string(name), entry} end),
      policies:
        Map.new(opts[:policies], fn {name, rules} -> {to_string(name), policy(rules)} end),
      middleware: opts[:middleware],
      idle_timeout: opts[:idle_timeout],
      trusted_workers: opts[:trusted_workers],
      egress: opts[:egress],
      prices:
        Map.new(opts[:prices], fn {spec, price} -> {to_string(spec), price(spec, price)} end)
    }
  end

  @doc """
  Returns the price of the model `spec`, in US dollars per million tokens.

      # Its own rates
      Wardrik.Setup.price("acme:model-1", input: 0.5, output: 1.5)

      # Another model's catalog price, 10% more
      Wardrik.Setup.price("zai_coding_plan:glm-5.1", priced_as: "zai:glm-5.1", markup: 0.1)

  ## Options

    * `:input` and `:output` - rates. Both required unless `:priced_as` is set.
    * `:cache_read` and `:cache_write` - optional rates.
    * `:priced_as` - a model whose catalog price to use. Can't be combined with rates.
    * `:markup` - added on top, as `0.1` for 10%. `0` unless set.

  Raises `ArgumentError` if the price is invalid.
  """
  @spec price(String.t(), keyword()) :: WardrikCore.Usage.price()
  def price(spec, price) do
    {markup, price} = Keyword.pop(price, :markup, 0)
    for {kind, rate} <- priced(spec, price), do: {kind, rate * (1 + marked_up(spec, markup))}
  end

  defp marked_up(_spec, markup) when is_number(markup), do: markup
  defp marked_up(spec, _markup), do: raise(ArgumentError, "#{spec}'s markup is a number.")

  defp priced(spec, price) do
    case Keyword.split(price, [:priced_as]) do
      {[], rates} ->
        rated(spec, rates)

      {[priced_as: model], []} ->
        twin(spec, model)

      {_priced_as, _rates} ->
        raise ArgumentError, "#{spec}'s price is another model's or its own."
    end
  end

  defp twin(spec, model) do
    case WardrikCore.price(model) do
      nil -> raise ArgumentError, "#{model} has no price in dollars to price #{spec} as."
      price -> price
    end
  end

  defp rated(spec, rates) do
    case Keyword.split(rates, [:input, :output, :cache_read, :cache_write]) do
      {rates, []} -> both(spec, rates)
      {_rates, [{key, _value} | _rest]} -> raise ArgumentError, "#{spec}'s price has no #{key}."
    end
  end

  defp both(spec, rates) do
    if Keyword.has_key?(rates, :input) and Keyword.has_key?(rates, :output),
      do: rates,
      else: raise(ArgumentError, "#{spec}'s price gives its input and output.")
  end

  @doc """
  Returns the options `WardrikCore.start_agent/2` takes for the agent `opts` describe.

  Adds Wardrik's events, prices, credentials and keys, spending, middleware and policies. The
  agent's own `:policy` is held alongside Wardrik's.
  """
  @spec agent(Wardrik.t(), keyword()) :: keyword()
  def agent(%Wardrik{} = wardrik, opts) do
    {policy, opts} = Keyword.pop(opts, :policy)
    policies = Enum.reject([wardrik.policy | policies(policy)], &is_nil/1)

    opts
    |> Keyword.put(:events, {WardrikEvents, Wardrik.events(wardrik)})
    |> Keyword.put_new(:prices, wardrik.prices)
    |> credentials(wardrik)
    |> wrapped([{Wardrik.Spending, wardrik.name} | wardrik.middleware])
    |> governed(policies)
  end

  @doc "Returns an agent's `:policy` as a list of policies. `nil` is `[]`."
  @spec policies(WardrikPolicy.t() | [WardrikPolicy.t()] | keyword() | map() | nil) ::
          [WardrikPolicy.t()]
  def policies(nil), do: []
  def policies([]), do: []
  def policies(%WardrikPolicy{} = policy), do: [policy]

  def policies([%WardrikPolicy{} | _rest] = policies), do: policies
  def policies(rules), do: [policy(rules)]

  @doc "Builds a policy from its rules. Returns a `WardrikPolicy` or `nil` as given."
  @spec policy(WardrikPolicy.t() | keyword() | map() | nil) :: WardrikPolicy.t() | nil
  def policy(nil), do: nil
  def policy(%WardrikPolicy{} = policy), do: policy
  def policy(rules), do: WardrikPolicy.new!(rules)

  defp store(_name, %WardrikStore{} = store), do: store
  defp store(name, nil), do: store(name, {WardrikStore.ETS, []})

  defp store(name, {adapter, opts}) when is_atom(adapter) and is_list(opts),
    do: built(adapter, Keyword.put_new(opts, :name, Module.concat(name, Store)))

  defp store(_name, store) do
    raise ArgumentError,
          "Give Wardrik's :store as {adapter, opts}, as {WardrikStore.EKV, data_dir: \"/var/lib/my_app\"}, " <>
            "or a built %WardrikStore{}, got: #{inspect(store)}"
  end

  defp built(adapter, opts) do
    if Code.ensure_loaded?(adapter),
      do: adapter.new(opts),
      else: raise(ArgumentError, unavailable(adapter))
  end

  defp unavailable(WardrikStore.Ecto),
    do:
      "WardrikStore.Ecto is only compiled alongside :ecto_sql and :postgrex; add them to your deps."

  defp unavailable(adapter),
    do: "#{inspect(adapter)} isn't compiled; add the dependency it comes with to your deps."

  defp backend(store, nil), do: {WardrikStore.Durable, store: store}

  defp backend(store, interval),
    do: {WardrikStore.Durable, store: store, discovery_interval_ms: interval}

  defp oauth(nil, _keys), do: nil

  defp oauth(_oauth, []),
    do: raise(ArgumentError, "Give Wardrik :keys to seal what people sign in with.")

  defp oauth(oauth, _keys),
    do: NimbleOptions.validate!(oauth, @oauth)

  defp credentials(opts, %Wardrik{keys: []}), do: opts

  defp credentials(opts, wardrik) do
    vault = Wardrik.vault(wardrik)

    opts
    |> Keyword.put_new(:credentials, {WardrikVault, vault})
    |> Keyword.put_new(:keys, {Wardrik.Keys, vault})
  end

  defp wrapped(opts, middleware),
    do: Keyword.update(opts, :middleware, middleware, &(middleware ++ &1))

  defp governed(opts, []), do: opts

  defp governed(opts, policies) do
    middleware = {WardrikPolicy.Middleware, policies}
    Keyword.update(opts, :middleware, [middleware], &[middleware | &1])
  end
end
