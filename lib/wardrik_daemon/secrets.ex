defmodule WardrikDaemon.Secrets do
  @moduledoc """
  Each owner's secrets, sealed in the vault and served at `/v1/owners/{owner}/secrets`.

      echo "$KEY" | wardrik vault put ANTHROPIC_API_KEY --for api_key
      echo "$KEY" | wardrik vault put CRM_KEY --org acme --for header

  Each is sealed for one purpose, and read only for it:

    * `api_key` - a service's API key, such as a model provider's. See `WardrikDaemon.Keys`.
    * `client_secret` - an OAuth app's client secret.
    * `header` - a value an MCP server's header sends.
    * `signing_secret` - signs or checks a webhook.

  The owner `deployment` holds the deployment's secrets, which `${NAME}` in `config.yaml` reads.
  Agents never reach them, except API keys with `deployment_keys: true`.

  Sealing or removing one records `secret.stored` or `secret.removed` in the audit, and
  reconnects the MCP servers whose headers read it.
  """

  alias WardrikCore.Principal
  alias WardrikVault.Secret

  @purposes %{
    "api_key" => :api_key,
    "client_secret" => :client_secret,
    "header" => :header,
    "signing_secret" => :signing_secret
  }

  @doc "Returns the purposes a secret is sealed for."
  @spec purposes() :: [String.t()]
  def purposes, do: Map.keys(@purposes)

  @doc """
  Lists `owner`'s secrets by name and purpose, never values. Connected accounts show as `grant`,
  chat app installs as `token`.
  """
  @spec list(atom(), String.t()) :: [%{String.t() => String.t()}]
  def list(wardrik, owner) do
    secrets =
      for {^owner, name, kind} <- WardrikVault.list(vault(wardrik)),
          do: %{"name" => name, "purpose" => Atom.to_string(kind)}

    Enum.sort_by(secrets, & &1["name"])
  end

  @doc """
  Seals `secret` for `purpose`, replacing any of that name. `actor` is recorded in the audit.
  """
  @spec put(atom(), Secret.t(), keyword()) :: :ok | {:error, term()}
  def put(wardrik, %Secret{principal: %Principal{id: owner}, name: name} = secret, opts) do
    kind = Map.fetch!(@purposes, Keyword.fetch!(opts, :purpose))

    with {:ok, _vsn} <- WardrikVault.put(vault(wardrik), secret, kind: kind),
         do: changed(wardrik, "secret.stored", {owner, name}, opts[:actor])
  end

  @doc "Removes `owner`'s secret `name`, as `actor`. Succeeds if there's none."
  @spec delete(atom(), {String.t(), String.t()}, Principal.t() | nil) :: :ok | {:error, term()}
  def delete(wardrik, {owner, name} = secret, actor) do
    with :ok <- WardrikVault.delete(vault(wardrik), %Principal{id: owner}, name),
         do: changed(wardrik, "secret.removed", secret, actor)
  end

  # The owner's servers whose headers name the secret connect again, to read it as it is now:
  # here before answering, and on the cluster's other nodes as the message reaches them.
  defp changed(wardrik, type, {owner, name}, actor) do
    running = Wardrik.Instance.fetch!(wardrik)
    mcp = Wardrik.mcp(running)
    reconnected = [owner: owner, secret: name]
    :ok = WardrikMCP.reconnect(mcp, reconnected)
    :ok = :erpc.multicast(Node.list(), WardrikMCP, :reconnect, [mcp, reconnected])

    change = {type, "secrets/" <> name, %{"secret" => %{"name" => name}, "owner" => owner}}
    WardrikEvents.record(Wardrik.events(running), change, actor: actor)
  end

  defp vault(wardrik), do: wardrik |> Wardrik.Instance.fetch!() |> Wardrik.vault()
end
