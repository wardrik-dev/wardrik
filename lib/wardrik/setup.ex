defmodule Wardrik.Setup do
  @moduledoc """
  Builds a Wardrik from its options, and the options each agent it starts begins with.
  """

  @doc "Builds a Wardrik from `opts`, as `Wardrik.start_link/1` takes them."
  @spec wardrik(keyword()) :: Wardrik.t()
  def wardrik(opts) do
    opts =
      Keyword.validate!(opts, [
        :name,
        :store,
        :data_dir,
        :backend,
        :policy,
        :oauth,
        :mcp,
        :declarations,
        :workspace,
        :notify,
        :orgs,
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
    {store, own_store} = store(name, opts[:store], opts[:data_dir])

    %Wardrik{
      name: name,
      store: store,
      own_store: own_store,
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
      backend: opts[:backend] || {WardrikStore.Durable, store: store},
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
  Returns what the model `spec` costs, in US dollars per million tokens, as `price` gives it: its
  own `:input` and `:output`, and `:cache_read` and `:cache_write`, or another model's catalog
  price, as `priced_as: "zai:glm-5.1"`, and either with a `:markup`, `0.1` for 10% more.
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
  Returns the options `WardrikCore.start_agent/2` takes for the agent `opts` describe: its events
  written to `wardrik`'s, its credentials and keys from `wardrik`'s vault, its spending counted, and wrapped
  in `wardrik`'s middleware and policies, its own `:policy` among them.
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

  @doc "Returns the policies an agent's `:policy` names: none, one, or a list of them."
  @spec policies(WardrikPolicy.t() | [WardrikPolicy.t()] | keyword() | map() | nil) ::
          [WardrikPolicy.t()]
  def policies(nil), do: []
  def policies([]), do: []
  def policies(%WardrikPolicy{} = policy), do: [policy]

  def policies([%WardrikPolicy{} | _rest] = policies), do: policies
  def policies(rules), do: [policy(rules)]

  @doc "Builds a policy from its rules, or returns the one given."
  @spec policy(WardrikPolicy.t() | keyword() | map() | nil) :: WardrikPolicy.t() | nil
  def policy(nil), do: nil
  def policy(%WardrikPolicy{} = policy), do: policy
  def policy(rules), do: WardrikPolicy.new!(rules)

  defp store(name, nil, nil), do: {WardrikStore.ETS.new(name: Module.concat(name, Store)), true}

  defp store(name, nil, data_dir),
    do: {WardrikStore.EKV.new(name: Module.concat(name, Store), data_dir: data_dir), true}

  defp store(_name, store, nil), do: {store, false}

  defp store(_name, _store, _data_dir),
    do: raise(ArgumentError, "Give Wardrik a :store or a :data_dir, not both.")

  defp oauth(nil, _keys), do: nil

  defp oauth(_oauth, []),
    do: raise(ArgumentError, "Give Wardrik :keys to seal what people sign in with.")

  defp oauth(oauth, _keys),
    do: Keyword.validate!(oauth, [:page, :providers, :client_name, req_options: []])

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
