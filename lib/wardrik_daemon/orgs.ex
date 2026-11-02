defmodule WardrikDaemon.Orgs do
  @moduledoc """
  Says which orgs the daemon runs agents for, and the policies and ceilings each is held to.
  `WardrikDaemon.Resolver` holds each agent to its org's.

  Those orgs are the deployment's own `org` and each one `config.yaml`'s `orgs` names. Any other
  org is refused: nothing is defined, started or kept for it.

  Each org is held to `"*"`'s policy, then its own, both from `policies/`. An org whose policy
  isn't in `policies/` runs none of its agents.

  A policy's budget is shared by all of an org's agents, as a `WardrikDaemon.Ceiling` named after
  the policy. Each org spends `"*"`'s budget apart from the others. A budget `per: turn` stays each
  agent's own, since a turn is one agent's.
  """

  alias Wardrik.Error
  alias WardrikDaemon.Ceiling

  @typedoc "An org's policies, held to in turn, and the ceilings its agents share."
  @type settings() :: %{policy: [WardrikPolicy.t()], ceilings: [Ceiling.t()]}

  @doc "Returns `:ok` if the daemon runs `org`, or else a `not_found` error."
  @spec known(String.t(), map()) :: :ok | {:error, Error.t()}
  def known(org, %{org: own, orgs: orgs}) do
    if org == own or Map.has_key?(orgs, org),
      do: :ok,
      else: {:error, Error.new(:not_found, "There's no org #{org} here: #{declared(own, orgs)}.")}
  end

  @doc """
  Returns `org`'s settings, or an error if the daemon doesn't run it or its policy is missing.

  `opts` holds `config.yaml`'s `:org` and `:orgs`, and the `:policies` in `policies/`.
  """
  @spec settings(String.t(), map()) :: {:ok, settings()} | {:error, Error.t()}
  def settings(org, %{orgs: orgs, policies: policies} = opts) do
    with :ok <- known(org, opts), do: held(org, names(orgs, org), policies)
  end

  defp names(orgs, org) do
    [orgs["*"], orgs[org]]
    |> Enum.map(&(&1 && &1.policy))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp held(org, names, policies) do
    case Enum.reject(names, &Map.has_key?(policies, &1)) do
      [] ->
        split = Enum.map(names, &pooled(&1, Map.fetch!(policies, &1)))

        with {:ok, ceilings} <- ceilings(org, split),
             do: {:ok, %{policy: Enum.map(split, &elem(&1, 1)), ceilings: ceilings}}

      [name | _rest] ->
        {:error,
         Error.new(
           :invalid_request,
           "#{org} is held to the policy #{name}, which policies/ doesn't hold, so its agents don't run."
         )}
    end
  end

  defp ceilings(org, split) do
    Enum.reduce_while(Enum.reverse(split), {:ok, []}, fn
      {_name, _policy, nil}, built ->
        {:cont, built}

      {name, _policy, budget}, {:ok, built} ->
        case Ceiling.new(name, budget) do
          {:ok, ceiling} ->
            {:cont, {:ok, [ceiling | built]}}

          {:error, why} ->
            {:halt, {:error, Error.new(:invalid_request, "#{org}'s ceiling #{name}: #{why}.")}}
        end
    end)
  end

  defp pooled(name, %WardrikPolicy{budget: %WardrikPolicy.Budget{per: per} = budget} = policy)
       when per != :turn,
       do: {name, %{policy | budget: nil}, budget}

  defp pooled(name, policy), do: {name, policy, nil}

  defp declared(own, orgs) do
    named = Enum.sort([own | Map.keys(orgs) -- ["*"]])
    "config.yaml declares #{Enum.join(Enum.uniq(named), ", ")}"
  end
end
