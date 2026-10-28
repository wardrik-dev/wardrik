defmodule Wardrik.Keys do
  @moduledoc """
  The keys an agent's installed code calls services with, as `WardrikCore.Keys`, from the vault:
  the agent's owner's, then its org's for a person's agent, then the deployment's.

  So an org, or a person, brings its own key by sealing a secret of that name, as
  `Wardrik.put_secret(MyApp.Wardrik, "acme", "ZAI_API_KEY", key)`, and the deployment's serves every
  owner that holds none. Where none of them holds it, the code finds its own, as ReqLLM reads the
  environment. Only secrets count: an account someone connected is a credential, never a key.
  """

  @behaviour WardrikCore.Keys

  alias Wardrik.Resource
  alias WardrikCore.Principal

  @impl WardrikCore.Keys
  def fetch(name, principal, vault) do
    Enum.find_value(owners(principal), :error, &held(vault, &1, name))
  end

  @doc "Returns whose keys an agent working for `principal` reads, nearest first."
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
