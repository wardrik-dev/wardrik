defmodule WardrikDaemon.Keys do
  @moduledoc """
  Finds the API keys agents call models and tools with. It's the daemon's `Wardrik.Keys`.

      echo "$KEY" | wardrik vault put ZAI_API_KEY --org acme --for api_key

  It looks for a secret sealed for `api_key` by the key's name: the agent's owner's, else one
  another owner lets it use, as `WardrikDaemon.Authorizer` allows `secret.use` (its org's), else
  the deployment's, with `config.yaml`'s `deployment_keys: true` (the default).

  Where none holds it, the library reads the environment, as ReqLLM does.

  ## Options

    * `:wardrik` - required. The Wardrik whose vault holds the keys.
    * `:deployment` - `true` to fall back to the deployment's keys. `false` unless set.
  """

  @behaviour Wardrik.Keys

  alias Wardrik.Owned
  alias Wardrik.Principal

  @impl Wardrik.Keys
  def fetch(%Wardrik.Keys.Request{name: name, principal: principal}, opts) do
    wardrik =
      opts
      |> Keyword.fetch!(:wardrik)
      |> Wardrik.Instance.fetch!()

    deployment? = Keyword.get(opts, :deployment, false)
    vault = Wardrik.vault(wardrik)

    candidates =
      for {owner, ^name, :api_key} <- Wardrik.Vault.list(vault),
          deployment? or owner != Owned.deployment(),
          do: %{owner: owner, name: name}

    case chosen(wardrik, principal, candidates) do
      %{owner: owner} -> Wardrik.Vault.fetch(vault, %Principal{id: owner}, name, kind: :api_key)
      _none -> {:error, :not_found}
    end
  end

  defp chosen(_wardrik, nil, candidates),
    do: Enum.find(candidates, &(&1.owner == Owned.deployment()))

  defp chosen(wardrik, principal, candidates),
    do: Owned.chosen(wardrik, principal, candidates, {"secret.use", :secret})
end
