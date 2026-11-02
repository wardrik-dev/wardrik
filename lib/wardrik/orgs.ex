defmodule Wardrik.Orgs do
  @moduledoc """
  Gives each org its own settings, alongside the deployment's. See `Wardrik.OrgSettings`.

      Wardrik.start_link(name: MyApp.AgentRuntime, orgs: {MyApp.Orgs, []})

      defmodule MyApp.Orgs do
        @behaviour Wardrik.Orgs

        @impl true
        def settings(org, _config) do
          plan = MyApp.Billing.plan!(org)
          {:ok, %Wardrik.OrgSettings{ceilings: %{"plan" => [usd: plan.usd, per: :month]}}}
        end
      end

  An agent's org is the first part of its ID: `acme` for `acme/@maria/assistant`.

  Wardrik reads an org's settings each time one of its agents is resolved (see
  `Wardrik.Resolver`). To apply new settings to awake agents, call `Wardrik.refresh/2`. Invalid
  settings stop the agent from starting, with the reason.

  For an org that doesn't exist, return an error:

      {:error, Wardrik.Error.new(:not_found, "There's no org globex here.")}

  Its agents then can't start or be defined, and no secrets, servers or tokens can be stored for it.
  """

  alias Wardrik.AgentID
  alias Wardrik.Ceiling
  alias Wardrik.Error
  alias Wardrik.OrgSettings
  alias Wardrik.Owners
  alias Wardrik.Resolver
  alias Wardrik.Resource

  @doc "Returns `org`'s settings, or an error if it doesn't exist."
  @callback settings(org :: String.t(), config :: term()) ::
              {:ok, OrgSettings.t()} | {:error, term()}

  @doc """
  Returns the org of the agent or owner `id`.

      Wardrik.Orgs.org("acme/@maria/assistant")
      #=> "acme"

  The deployment's is `"deployment"`. An `id` that's neither is returned as it is.
  """
  @spec org(String.t()) :: String.t()
  def org(id) do
    case id |> owner() |> Owners.parse() do
      {:ok, %{org: nil}} -> Resource.deployment()
      {:ok, %{org: org}} -> org
      :error -> id
    end
  end

  defp owner(id) do
    case AgentID.parse(id) do
      {:ok, %AgentID{owner: owner}} -> owner
      :error -> id
    end
  end

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

  @doc "Returns the middleware that holds the org's agents to its ceilings."
  @spec middleware(Wardrik.t(), String.t(), OrgSettings.t()) :: [WardrikCore.Context.entry()]
  def middleware(_wardrik, _org, %OrgSettings{ceilings: ceilings}) when ceilings == %{}, do: []

  def middleware(wardrik, org, %OrgSettings{ceilings: ceilings}),
    do: [{Ceiling, %{wardrik: wardrik.name, org: org, ceilings: Map.values(ceilings)}}]

  @doc """
  Returns what the org's agents have spent against each ceiling, by name. See
  `Wardrik.Ceiling.spent/3`.

      Wardrik.Orgs.spent(MyApp.AgentRuntime, "acme")
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
    unread = &unread(org, &1)

    with {:ok, policy} <- Resolver.policy("policy", settings.policy, unread),
         {:ok, policies} <- Resolver.policies(wardrik, settings.policies, unread),
         {:ok, ceilings} <- ceilings(settings.ceilings, unread) do
      {:ok,
       %OrgSettings{
         policy: policy,
         policies: policies,
         defaults: Wardrik.Type.json(settings.defaults),
         ceilings: ceilings
       }}
    end
  end

  defp ceilings(ceilings, unread) do
    ceilings
    |> Map.new(fn {name, settings} -> {to_string(name), settings} end)
    |> Resolver.each(fn name, settings ->
      case Ceiling.new(name, settings) do
        {:ok, ceiling} -> {:ok, ceiling}
        {:error, why} -> {:error, unread.("its ceiling #{name}: #{why}")}
      end
    end)
  end

  defp unread(org, why), do: Error.new(:invalid_request, "#{org}'s settings don't read: #{why}.")
end
