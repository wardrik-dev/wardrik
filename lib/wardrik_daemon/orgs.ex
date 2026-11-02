defmodule WardrikDaemon.Orgs do
  @moduledoc """
  The orgs the daemon runs agents for, and the policies and ceilings each is held to.

    * The orgs are `config.yaml`'s `org` and each in `orgs`. Any other is refused.
    * Each is held to `"*"`'s policy, then its own. An org whose policy is missing runs no agents.
    * A policy's budget is shared by the org's agents, as a `WardrikDaemon.Ceiling`. Each org
      spends `"*"`'s budget separately. A `per: turn` budget stays each agent's own.
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
