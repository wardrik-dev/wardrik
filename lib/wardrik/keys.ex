defmodule Wardrik.Keys do
  @moduledoc """
  Finds the API keys an agent's code calls services with. Implements `WardrikCore.Keys`.

  Keys are secrets in the vault. Wardrik looks in this order:

    1. The person, for a person's agent.
    2. The org.
    3. The deployment, only if Wardrik starts with `deployment_keys: true`.

  An org or person brings its own key by sealing it with the key's name, as an `:api_key`:

      Wardrik.put_secret(MyApp.AgentRuntime, "acme", "ZAI_API_KEY", key, kind: :api_key)

  If no one holds it, the code finds its own, as ReqLLM reads the environment. Only `:api_key`
  secrets count, so a client secret, header or signing secret is never read as a key. A connected
  account is a credential, never a key.

  ## Options

    * `:vault` - required. The vault the keys are sealed in.
    * `:deployment` - `true` to fall back to the deployment's keys. `false` unless set.
  """

  @behaviour WardrikCore.Keys

  alias Wardrik.Owners
  alias Wardrik.Resource
  alias WardrikCore.Principal

  @impl WardrikCore.Keys
  def fetch(name, principal, opts) do
    vault = Keyword.fetch!(opts, :vault)
    owners = owners(principal, Keyword.get(opts, :deployment, false))
    Enum.find_value(owners, :error, &held(vault, &1, name))
  end

  @doc """
  Returns the owners whose keys an agent working for `principal` uses, nearest first.

      Wardrik.Keys.owners(%WardrikCore.Principal{id: "acme/@jon"}, false)
      #=> ["acme/@jon", "acme"]
  """
  @spec owners(Principal.t() | nil, boolean()) :: [String.t()]
  def owners(%Principal{id: id}, true), do: Owners.chain(id)

  def owners(%Principal{id: id}, false) do
    [nearest | further] = Owners.chain(id)
    [nearest | List.delete(further, Resource.deployment())]
  end

  def owners(nil, true), do: [Resource.deployment()]
  def owners(nil, false), do: []

  defp held(vault, owner, name) do
    case WardrikVault.fetch(vault, %Principal{id: owner}, name, kind: :api_key) do
      {:ok, key} -> {:ok, key}
      _none -> nil
    end
  end
end
