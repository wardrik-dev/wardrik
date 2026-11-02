defmodule WardrikDaemon.Keys do
  @moduledoc """
  Finds the API keys an agent's model and tools call services with. It's the daemon's
  `WardrikCore.Keys`.

  Keys are secrets sealed as `api_key`, looked for in this order:

    1. The agent's owner: a person, or its org.
    2. The person's org.
    3. The deployment, only with `config.yaml`'s `deployment_keys: true`. Code working for the
       deployment itself always uses them.

  An org or person brings its own key by sealing it under the key's name:

      echo "$KEY" | wardrik vault put ZAI_API_KEY --org acme --for api_key

  A secret sealed for any other purpose is never read as a key, nor is a connected account.
  Where no one holds it, the code finds its own, as ReqLLM reads the environment.

  ## Options

    * `:wardrik` - required. The Wardrik whose vault the keys are sealed in.
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
  Returns the owners whose keys an agent working for `principal` uses, nearest first.

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
