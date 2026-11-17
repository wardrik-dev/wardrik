defmodule Wardrik.Setup do
  @moduledoc "Builds Wardrik's and each agent's options."

  @doc "Builds a `%Wardrik{}` from validated `Wardrik.start_link/1` options."
  @spec wardrik(keyword()) :: Wardrik.t()
  def wardrik(opts) do
    name = Keyword.fetch!(opts, :name)
    store = store(name, opts[:store])
    vault = Module.concat(name, Vault)
    credentials = opts[:credentials] || vault(opts[:vault_keys], {Wardrik.Vault, vault})

    %Wardrik{
      name: name,
      store: store,
      vault_keys: opts[:vault_keys],
      credentials: choose_credentials(opts[:broker], name, credentials),
      broker: build_broker_settings(opts[:broker], credentials),
      key_source: opts[:key_source],
      grants: opts[:grants] || grants(opts[:oauth], Module.concat(name, OAuth)),
      oauth: oauth(opts[:oauth], opts[:vault_keys]),
      mcp: opts[:mcp],
      listeners: opts[:listeners],
      sinks: opts[:sinks],
      channels: Map.new(opts[:channels], fn {name, entry} -> {to_string(name), entry} end),
      notify: Wardrik.Notify.settings(opts[:notify]),
      declarations: opts[:declarations],
      resolver: opts[:resolver],
      defaults: Wardrik.Type.json(opts[:defaults]),
      triggers: opts[:triggers],
      deployment: opts[:deployment],
      authorizer: opts[:authorizer],
      retention: opts[:retention],
      backend: opts[:backend] || backend(store, opts[:discovery_interval_ms]),
      agents: opts[:agents],
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
        Map.new(opts[:prices], fn {spec, price} -> {to_string(spec), price(spec, price)} end),
      model_options: opts[:model_options],
      endpoints: Map.new(opts[:endpoints], fn {name, endpoint} -> {to_string(name), endpoint} end)
    }
  end

  @doc """
  Returns the price of the model `spec`, in dollars per million tokens. Wardrik's `:prices` uses it.

      # Its own rates
      Wardrik.Setup.price("acme:model-1", input: 0.5, output: 1.5)

      # Another model's catalog price, plus 10%
      Wardrik.Setup.price("zai_coding_plan:glm-5.1", priced_as: "zai:glm-5.1", markup: 0.1)

  ## Options

    * `:input`, `:output` - rates. Required without `:priced_as`.
    * `:cache_read`, `:cache_write` - optional rates.
    * `:priced_as` - a model whose catalog price to use, instead of rates.
    * `:markup` - added on top, as `0.1`. `0` unless set.

  Raises `ArgumentError` on an invalid price.
  """
  @spec price(String.t(), keyword()) :: WardrikCore.price()
  def price(spec, price) do
    {markup, price} = Keyword.pop(price, :markup, 0)
    for {kind, rate} <- apply_price(spec, price), do: {kind, rate * (1 + mark_up(spec, markup))}
  end

  defp mark_up(_spec, markup) when is_number(markup), do: markup
  defp mark_up(spec, _markup), do: raise(ArgumentError, "#{spec}'s markup is a number.")

  defp apply_price(spec, price) do
    case Keyword.split(price, [:priced_as]) do
      {[], rates} ->
        rate(spec, rates)

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

  defp rate(spec, rates) do
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
  Returns `WardrikCore.start_agent/2`'s options for the agent `opts` describe, with Wardrik's added.
  """
  @spec agent(Wardrik.t(), keyword()) :: keyword()
  def agent(%Wardrik{} = wardrik, opts) do
    {policy, opts} = Keyword.pop(opts, :policy)
    policies = Enum.reject([wardrik.policy | policies(policy)], &is_nil/1)

    opts
    |> Keyword.put(:events, {Wardrik.EventLog, Wardrik.events(wardrik)})
    |> Keyword.put_new(:prices, wardrik.prices)
    |> Keyword.put_new(:endpoints, wardrik.endpoints)
    |> model_options(wardrik)
    |> credentials(wardrik)
    |> wrap([{Wardrik.Spending, wardrik.name} | wardrik.middleware])
    |> apply_governance(policies)
  end

  defp model_options(opts, wardrik),
    do:
      Keyword.put(
        opts,
        :model_options,
        Keyword.merge(wardrik.model_options, Keyword.get(opts, :model_options, []))
      )

  @doc "Returns an agent's `:policy` as a list of policies. `nil` is `[]`."
  @spec policies(Wardrik.Policy.t() | [Wardrik.Policy.t()] | keyword() | map() | nil) ::
          [Wardrik.Policy.t()]
  def policies(nil), do: []
  def policies([]), do: []
  def policies(%Wardrik.Policy{} = policy), do: [policy]

  def policies([%Wardrik.Policy{} | _rest] = policies), do: policies
  def policies(rules), do: [policy(rules)]

  @doc "Builds a policy from its rules."
  @spec policy(Wardrik.Policy.t() | keyword() | map() | nil) :: Wardrik.Policy.t() | nil
  def policy(nil), do: nil
  def policy(%Wardrik.Policy{} = policy), do: policy
  def policy(rules), do: Wardrik.Policy.new!(rules)

  defp store(_name, %Wardrik.Store{} = store), do: store
  defp store(name, nil), do: store(name, {Wardrik.Store.ETS, []})

  defp store(name, {adapter, opts}),
    do: build(adapter, Keyword.put_new(opts, :name, Module.concat(name, Store)))

  defp build(adapter, opts) do
    if Code.ensure_loaded?(adapter),
      do: adapter.new(opts),
      else: raise(ArgumentError, unavailable(adapter))
  end

  defp unavailable(Wardrik.Store.Ecto),
    do:
      "Wardrik.Store.Ecto is only compiled alongside :ecto_sql and :postgrex; add them to your deps."

  defp unavailable(adapter),
    do: "#{inspect(adapter)} isn't compiled; add the dependency it comes with to your deps."

  defp backend(store, nil), do: {Wardrik.Store.Durable, store: store}

  defp backend(store, interval),
    do: {Wardrik.Store.Durable, store: store, discovery_interval_ms: interval}

  defp oauth(nil, _keys), do: nil

  defp oauth(_oauth, []),
    do: raise(ArgumentError, "Give Wardrik :vault_keys to seal what people sign in with.")

  defp oauth(oauth, _keys), do: oauth

  # A broker answers its credentials, and hands the rest to what would answer without it.
  defp choose_credentials(nil, _name, credentials), do: credentials
  defp choose_credentials(_broker, name, _credentials), do: {Wardrik.Credentials.Broker, name}

  defp build_broker_settings(nil, _credentials), do: nil
  defp build_broker_settings(broker, credentials), do: Map.new([fallback: credentials] ++ broker)

  defp vault([], _entry), do: nil
  defp vault(_keys, entry), do: entry

  defp grants(nil, _oauth), do: nil
  defp grants(_oauth, name), do: {Wardrik.OAuth, name}

  defp credentials(opts, wardrik) do
    opts
    |> give(:credentials, wardrik.credentials)
    |> give(:keys, wardrik.key_source)
  end

  defp give(opts, _key, nil), do: opts
  defp give(opts, key, entry), do: Keyword.put_new(opts, key, entry)

  defp wrap(opts, middleware),
    do: Keyword.update(opts, :middleware, middleware, &(middleware ++ &1))

  defp apply_governance(opts, []), do: opts

  defp apply_governance(opts, policies) do
    middleware = {Wardrik.Policy.Middleware, policies}
    Keyword.update(opts, :middleware, [middleware], &[middleware | &1])
  end
end
