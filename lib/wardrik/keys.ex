defmodule Wardrik.Keys do
  @moduledoc """
  Finds the API keys an agent's code calls services with. Implements `WardrikCore.Keys`.

  Keys are secrets in the vault. Wardrik looks in this order:

    1. The person, for a person's agent.
    2. The org.
    3. The deployment.

  An org or person brings its own key by sealing a secret with the key's name:

      Wardrik.put_secret(MyApp.Wardrik, "acme", "ZAI_API_KEY", key)

  If no one holds it, the code finds its own, as ReqLLM reads the environment. Only secrets
  count. A connected account is a credential, never a key.
  """

  @behaviour WardrikCore.Keys

  alias Wardrik.Resource
  alias WardrikCore.Principal

  @impl WardrikCore.Keys
  def fetch(name, principal, vault) do
    Enum.find_value(owners(principal), :error, &held(vault, &1, name))
  end

  @doc "Returns the owners whose keys an agent working for `principal` uses, nearest first."
  @spec owners(Principal.t() | nil) :: [String.t()]
  def owners(%Principal{id: id}) do
    case String.split(id, "/@", parts: 2) do
      [org, _person] -> [id, org, Resource.deployment()]
      [org] -> [org, Resource.deployment()]
    end
  end

  def owners(nil), do: [Resource.deployment()]

  defp held(vault, owner, name) do
    case WardrikVault.lookup(vault, %Principal{id: owner}, name) do
      {:ok, :secret, key, _vsn} -> {:ok, key}
      _none -> nil
    end
  end
end
