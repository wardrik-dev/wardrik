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
        idle_timeout: 900
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
      declarations: opts[:declarations],
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
      idle_timeout: opts[:idle_timeout]
    }
  end

  @doc """
  Returns the options `WardrikCore.start_agent/2` takes for the agent `opts` describe: its events
  written to `wardrik`'s, its credentials from `wardrik`'s vault, and wrapped in `wardrik`'s
  middleware and policies, its own `:policy` among them.
  """
  @spec agent(Wardrik.t(), keyword()) :: keyword()
  def agent(%Wardrik{} = wardrik, opts) do
    {policy, opts} = Keyword.pop(opts, :policy)
    policies = Enum.reject([wardrik.policy | policies(policy)], &is_nil/1)

    opts
    |> Keyword.put(:events, {WardrikEvents, Wardrik.events(wardrik)})
    |> credentials(wardrik)
    |> wrapped(wardrik.middleware)
    |> governed(policies)
  end

  defp policies(nil), do: []
  defp policies([]), do: []
  defp policies(%WardrikPolicy{} = policy), do: [policy]

  defp policies([%WardrikPolicy{} | _rest] = policies), do: policies
  defp policies(rules), do: [policy(rules)]

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

  defp oauth(oauth, _keys), do: Keyword.validate!(oauth, [:page, :providers, req_options: []])

  defp credentials(opts, %Wardrik{keys: []}), do: opts

  defp credentials(opts, wardrik),
    do: Keyword.put_new(opts, :credentials, {WardrikVault, Wardrik.vault(wardrik)})

  defp wrapped(opts, []), do: opts

  defp wrapped(opts, middleware),
    do: Keyword.update(opts, :middleware, middleware, &(middleware ++ &1))

  defp governed(opts, []), do: opts

  defp governed(opts, policies) do
    middleware = {WardrikPolicy.Middleware, policies}
    Keyword.update(opts, :middleware, [middleware], &[middleware | &1])
  end
end
