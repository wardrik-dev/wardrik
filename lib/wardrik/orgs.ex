defmodule Wardrik.Orgs do
  @moduledoc """
  Gives each org its own settings, alongside the deployment's. See `Wardrik.OrgSettings`.

      Wardrik.start_link(name: MyApp.Wardrik, orgs: {MyApp.Orgs, []})

      defmodule MyApp.Orgs do
        @behaviour Wardrik.Orgs

        @impl true
        def settings(org, _config) do
          plan = MyApp.Billing.plan!(org)
          {:ok, %Wardrik.OrgSettings{ceilings: %{"plan" => [usd: plan.usd, per: :month]}}}
        end
      end

  An agent's org is the first part of its ID: `acme` for `acme/@maria/assistant`.

  Wardrik reads an org's settings each time one of its agents starts, wakes or is defined. To
  apply new settings to awake agents, call `Wardrik.refresh/2`. Invalid settings stop the agent
  from starting, with the reason.

  For an org that doesn't exist, return an error:

      {:error, Wardrik.Error.new(:not_found, "There's no org globex here.")}

  Its agents then can't start or be defined, and no secrets, servers or tokens can be stored for it.
  """

  alias Wardrik.Ceiling
  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Operations.Running
  alias Wardrik.OrgSettings
  alias Wardrik.Setup

  @doc "Returns `org`'s settings, or an error if it doesn't exist."
  @callback settings(org :: String.t(), config :: term()) ::
              {:ok, OrgSettings.t()} | {:error, term()}

  @doc "Returns the org of the agent `id`."
  @spec org(String.t()) :: String.t()
  def org(id), do: id |> String.split("/", parts: 2) |> hd()

  @doc """
  Returns `org`'s settings, with each policy and ceiling built, or an error if they're invalid.

  Without `:orgs`, every org gets empty settings.
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
  Returns `:ok` if `org` exists, or the error `c:settings/2` returns.

  `"deployment"`, the deployment's own namespace, always exists.
  """
  @spec known(Wardrik.t(), String.t()) :: :ok | {:error, Error.t()}
  def known(_wardrik, "deployment"), do: :ok

  def known(wardrik, org) do
    with {:ok, _settings} <- settings(wardrik, org), do: :ok
  end

  @doc "Returns `wardrik` with the org's policies and defaults merged in."
  @spec within(Wardrik.t(), OrgSettings.t()) :: Wardrik.t()
  def within(wardrik, %OrgSettings{policies: policies, defaults: defaults}),
    do: %{
      wardrik
      | policies: Map.merge(wardrik.policies, policies),
        defaults: Map.merge(wardrik.defaults, defaults)
    }

  @doc "Returns the agent `id`'s defaults: the deployment's, overridden by its org's."
  @spec defaults(Wardrik.t(), String.t()) :: map()
  def defaults(wardrik, id) do
    case settings(wardrik, org(id)) do
      {:ok, settings} -> Map.merge(wardrik.defaults, settings.defaults)
      {:error, _error} -> wardrik.defaults
    end
  end

  @doc "Returns `opts` with the org's policy and ceilings added."
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

  @doc "Applies the org's current settings to its awake agents. Returns a line for each failure."
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
         {:ok, opts} <- Wardrik.Resolution.resolve(wardrik, id, definition),
         do: Running.bring(wardrik, opts)
  end

  @doc """
  Returns what the org's agents have spent against each ceiling, by name. See
  `Wardrik.Ceiling.spent/3`.

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
