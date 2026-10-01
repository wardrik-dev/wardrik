defmodule WardrikVault.Config do
  @moduledoc """
  Where `WardrikVault` reads its settings.

      config :wardrik, WardrikVault, keys: [System.fetch_env!("WARDRIK_VAULT_KEY")], grants: WardrikOAuth

  Every read of the application environment this package makes goes through
  here, so moving the setting to `config :wardrik_vault` changes one module.
  """

  @doc "The base64-encoded keys, the first of which seals."
  @spec keys() :: [String.t()]
  def keys, do: env() |> Keyword.get(:keys, []) |> List.wrap()

  @doc "The `WardrikVault.Grants` module that renews and asks for grants, or `nil`."
  @spec grants() :: module() | nil
  def grants, do: Keyword.get(env(), :grants)

  @doc "Whether a key is configured at all. `WardrikVault.ready?/0` says whether it is usable."
  @spec configured?() :: boolean()
  def configured?, do: keys() != []

  defp env, do: Application.get_env(:wardrik, WardrikVault, [])
end
