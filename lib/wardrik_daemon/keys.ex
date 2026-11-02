defmodule WardrikDaemon.Keys do
  @moduledoc """
  Finds the API keys agents call models and tools with. It's the daemon's `WardrikCore.Keys`.

      echo "$KEY" | wardrik vault put ZAI_API_KEY --org acme --for api_key

  It looks for a secret sealed for `api_key`, in this order:

    1. The agent's owner.
    2. The owner's org, for an agent a person owns.
    3. The deployment, with `config.yaml`'s `deployment_keys: true` (the default).

  Where none holds it, the library reads the environment, as ReqLLM does.

  ## Options

    * `:wardrik` - required. The Wardrik whose vault holds the keys.
    * `:deployment` - `true` to fall back to the deployment's keys. `false` unless set.
  """

  @behaviour WardrikCore.Keys

  alias WardrikCore.Principal
  alias WardrikDaemon.Owners

  @impl WardrikCore.Keys
  def fetch(%WardrikCore.Keys.Request{name: name, principal: principal}, opts) do
    vault = opts |> Keyword.fetch!(:wardrik) |> Wardrik.Instance.fetch!() |> Wardrik.vault()
    owners = owners(principal, Keyword.get(opts, :deployment, false))
    Enum.find_value(owners, :error, &held(vault, &1, name))
  end

  @doc """
  Returns the owners whose keys `principal`'s agents use, nearest first.

      WardrikDaemon.Keys.owners(%WardrikCore.Principal{id: "acme/@jon"}, false)
      #=> ["acme/@jon", "acme"]
  """
  @spec owners(Principal.t() | nil, boolean()) :: [String.t()]
  def owners(nil, true), do: ["deployment"]
  def owners(nil, false), do: []

  def owners(%Principal{id: id}, true), do: chain(id)

  def owners(%Principal{id: id}, false) do
    [nearest | further] = chain(id)
    [nearest | List.delete(further, "deployment")]
  end

  defp chain(id),
    do: if(Owners.valid?(id), do: Enum.uniq(Owners.chain(id)), else: [id, "deployment"])

  defp held(vault, owner, name) do
    case WardrikVault.fetch(vault, %Principal{id: owner}, name, kind: :api_key) do
      {:ok, key} -> {:ok, key}
      _none -> nil
    end
  end
end
