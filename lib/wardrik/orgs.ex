defmodule Wardrik.Orgs do
  @moduledoc """
  Orgs give their agents settings of their own beside the deployment's, as `Wardrik.OrgSettings`
  describes: a policy they're held to, policies and defaults their definitions may use, and
  ceilings they spend from together. A Wardrik takes them as `orgs: {module, config}`:

      defmodule MyApp.Orgs do
        @behaviour Wardrik.Orgs

        @impl true
        def settings(org, _config) do
          plan = MyApp.Billing.plan!(org)
          {:ok, %Wardrik.OrgSettings{ceilings: %{"plan" => [usd: plan.usd, per: :month]}}}
        end
      end

  An agent's org is the first part of its ID: `acme` for `acme/@maria/assistant`. Wardrik asks for
  an org's settings each time one of its agents starts, wakes or is defined, so an agent never runs
  on settings older than its start. `Wardrik.refresh/2` brings an org's awake agents to its
  settings as they read now. Settings that don't read keep the agent from starting, and say why.

  Answer `{:error, %Wardrik.Error{}}` for an org there's no such thing as, as
  `Wardrik.Error.new(:not_found, "There's no org globex here.")`: its agents don't start or get
  defined, and nothing is kept for it, as a secret, a server or a token over its agents.
  """

  alias Wardrik.Ceiling
  alias Wardrik.Definition
  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Operations.Running
  alias Wardrik.OrgSettings
  alias Wardrik.Setup

  @doc "Returns the settings of the org `org`, or an error saying why there are none."
  @callback settings(org :: String.t(), config :: term()) ::
              {:ok, OrgSettings.t()} | {:error, term()}

  @doc "Returns the org of the agent `id`."
  @spec org(String.t()) :: String.t()
  def org(id), do: id |> String.split("/", parts: 2) |> hd()

  @doc """
  Returns the settings of the org `org`, each policy and ceiling built, or an error saying why they
  don't read. A Wardrik without `:orgs` gives every org none.
  """
  @spec settings(Wardrik.t(), String.t()) :: {:ok, OrgSettings.t()} | {:error, Error.t()}
  def settings(%Wardrik{orgs: nil}, _org), do: {:ok, %OrgSettings{}}

  def settings(%Wardrik{orgs: {module, config}} = wardrik, org) do
    case module.settings(org, config) do
      {:ok, %OrgSettings{} = settings} ->
        read(wardrik, org, settings)

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{org}'s settings didn't read: #{inspect(reason)}")}
    end
  end

  @doc """
  Returns `:ok` where the org `org` is one the Wardrik's orgs know, or the error they answer. The
  deployment's own namespace, `deployment`, is always known.
  """
  @spec known(Wardrik.t(), String.t()) :: :ok | {:error, Error.t()}
  def known(_wardrik, "deployment"), do: :ok

  def known(wardrik, org) do
    with {:ok, _settings} <- settings(wardrik, org), do: :ok
  end

  @doc "Returns `wardrik` as the org's definitions read it: with its policies and defaults too."
  @spec within(Wardrik.t(), OrgSettings.t()) :: Wardrik.t()
  def within(wardrik, %OrgSettings{policies: policies, defaults: defaults}),
    do: %{
      wardrik
      | policies: Map.merge(wardrik.policies, policies),
        defaults: Map.merge(wardrik.defaults, defaults)
    }

  @doc "Returns what the agent `id`'s definition is given where it says nothing: the deployment's defaults, under its org's."
  @spec defaults(Wardrik.t(), String.t()) :: map()
  def defaults(wardrik, id) do
    case settings(wardrik, org(id)) do
      {:ok, settings} -> Map.merge(wardrik.defaults, settings.defaults)
      {:error, _error} -> wardrik.defaults
    end
  end

  @doc "Returns `opts` for an agent of the org `org`, held to its settings' policy and ceilings too."
  @spec hold(keyword(), Wardrik.t(), String.t(), OrgSettings.t()) :: keyword()
  def hold(opts, wardrik, org, %OrgSettings{policy: policy, ceilings: ceilings}) do
    held = List.wrap(policy)

    opts
    |> Keyword.update(:policy, held, &(held ++ Setup.policies(&1)))
    |> ceilinged(wardrik, org, Map.values(ceilings))
  end

  defp ceilinged(opts, _wardrik, _org, []), do: opts

  defp ceilinged(opts, wardrik, org, ceilings) do
    ceiling = {Ceiling, %{wardrik: wardrik.name, org: org, ceilings: ceilings}}
    Keyword.update(opts, :middleware, [ceiling], &(&1 ++ [ceiling]))
  end

  @doc "Brings the org's awake agents to its settings as they read now, and returns what it couldn't, a line each."
  @spec refresh(Wardrik.t(), String.t()) :: [String.t()]
  def refresh(wardrik, org) do
    for id <- Definitions.ids(wardrik),
        org(id) == org,
        Running.whereis(wardrik, id) != nil,
        {:error, error} <- [refreshed(wardrik, id)],
        do: "#{id}: #{error.message}"
  end

  defp refreshed(wardrik, id) do
    with {:ok, definition} <- Running.definition(wardrik, id),
         {:ok, opts} <- Definition.resolve(wardrik, id, definition),
         do: Running.bring(wardrik, opts)
  end

  @doc """
  Returns what the org's agents have spent against each of its ceilings, by name, as
  `Wardrik.Ceiling.spent/3` gives it.

      Wardrik.Orgs.spent(MyApp.Wardrik, "acme")
      #=> {:ok, %{"spending-cap" => %{limit: %{usd: 20.0, tokens: nil}, spent: %{usd: 12.4, tokens: 81_200}, ...}}}
  """
  @spec spent(atom() | Wardrik.t(), String.t()) ::
          {:ok, %{String.t() => map()}} | {:error, Error.t()}
  def spent(instance, org) do
    wardrik = Wardrik.Instance.fetch!(instance)

    with {:ok, settings} <- settings(wardrik, org),
         do:
           {:ok,
            Map.new(settings.ceilings, fn {name, ceiling} ->
              {name, Ceiling.spent(wardrik, org, ceiling)}
            end)}
  end

  defp read(wardrik, org, settings) do
    with {:ok, policy} <- policy(org, "policy", settings.policy),
         {:ok, policies} <- policies(wardrik, org, settings.policies),
         {:ok, ceilings} <- ceilings(org, settings.ceilings) do
      {:ok,
       %OrgSettings{
         policy: policy,
         policies: policies,
         defaults: Wardrik.Type.json(settings.defaults),
         ceilings: ceilings
       }}
    end
  end

  defp policies(wardrik, org, policies) do
    named = Map.new(policies, fn {name, rules} -> {to_string(name), rules} end)

    case Enum.find(Map.keys(named), &Map.has_key?(wardrik.policies, &1)) do
      nil ->
        each(named, &policy(org, "policy #{&1}", &2))

      name ->
        {:error, unread(org, "its policy #{name} has the name of one of the deployment's")}
    end
  end

  defp ceilings(org, ceilings) do
    ceilings
    |> Map.new(fn {name, settings} -> {to_string(name), settings} end)
    |> each(fn name, settings ->
      case Ceiling.new(name, settings) do
        {:ok, ceiling} -> {:ok, ceiling}
        {:error, why} -> {:error, unread(org, "its ceiling #{name}: #{why}")}
      end
    end)
  end

  defp each(named, read) do
    read = Map.new(named, fn {name, value} -> {name, read.(name, value)} end)

    case Enum.find(read, &match?({_name, {:error, _error}}, &1)) do
      nil -> {:ok, Map.new(read, fn {name, {:ok, value}} -> {name, value} end)}
      {_name, error} -> error
    end
  end

  defp policy(_org, _what, nil), do: {:ok, nil}

  defp policy(org, what, [first | _rest] = policies) when not is_tuple(first) do
    read =
      policies
      |> Enum.with_index(1)
      |> Enum.map(fn {policy, n} -> policy(org, "#{what} #{n}", policy) end)

    case Enum.find(read, &match?({:error, _error}, &1)) do
      nil -> {:ok, Enum.map(read, fn {:ok, policy} -> policy end)}
      error -> error
    end
  end

  defp policy(_org, _what, %WardrikPolicy{} = policy), do: {:ok, policy}

  defp policy(org, what, rules) when is_map(rules) do
    case WardrikPolicy.decode(rules) do
      {:ok, policy} -> {:ok, policy}
      {:error, why} -> {:error, unread(org, "its #{what}: #{why}")}
    end
  end

  defp policy(org, what, rules) do
    {:ok, WardrikPolicy.new!(rules)}
  rescue
    error in ArgumentError -> {:error, unread(org, "its #{what}: #{Exception.message(error)}")}
  end

  defp unread(org, why), do: Error.new(:invalid_request, "#{org}'s settings don't read: #{why}.")
end
