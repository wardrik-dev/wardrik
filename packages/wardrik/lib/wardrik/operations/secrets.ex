defmodule Wardrik.Operations.Secrets do
  @moduledoc false

  # An owner's secrets, sealed in the vault. The owner is the vault's principal ID, as the caller
  # names it: Wardrik never reads it.

  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Principal
  alias Wardrik.Scope
  alias Wardrik.Vault.Secret

  @purposes %{
    "api_key" => :api_key,
    "client_secret" => :client_secret,
    "header" => :header,
    "signing_secret" => :signing_secret
  }

  @doc "Lists the owner's secrets by name and purpose, never values."
  @spec list(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def list(%Scope{wardrik: wardrik}, %{"owner" => owner}) do
    with :ok <- sealing(wardrik) do
      vault = Wardrik.vault(wardrik)

      secrets =
        for {^owner, name, kind} <- Wardrik.Vault.list(vault),
            do: %{"name" => name, "purpose" => Atom.to_string(kind)}

      {:ok, %{"secrets" => Enum.sort_by(secrets, & &1["name"])}}
    end
  end

  @doc """
  Seals the value as the owner's secret, in place of any of that name, and reconnects the
  owner's MCP servers whose headers read it.
  """
  @spec put(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def put(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "name" => name} = input) do
    secret = %Secret{principal: %Principal{id: owner}, name: name, value: input["value"]}
    kind = Map.fetch!(@purposes, input["purpose"])

    with :ok <- sealing(wardrik) do
      vault = Wardrik.vault(wardrik)

      case Wardrik.Vault.put(vault, secret, kind: kind) do
        {:ok, _vsn} -> changed(scope, "secret.stored", {owner, name})
        {:error, reason} -> unkept(reason)
      end
    end
  end

  @doc "Removes the owner's secret. Removing none answers as removing one does."
  @spec delete(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def delete(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "name" => name}) do
    with :ok <- sealing(wardrik) do
      vault = Wardrik.vault(wardrik)

      case Wardrik.Vault.delete(vault, %Principal{id: owner}, name) do
        :ok -> changed(scope, "secret.removed", {owner, name})
        {:error, reason} -> unkept(reason)
      end
    end
  end

  # The owner's servers whose headers name the secret connect again, to read it as it is now:
  # here before answering, and on the cluster's other nodes as the message reaches them.
  defp changed(%Scope{wardrik: wardrik} = scope, type, {owner, name}) do
    mcp = Wardrik.mcp(wardrik)
    reconnected = [owner: owner, secret: name]
    :ok = Wardrik.MCP.reconnect(mcp, reconnected)
    :ok = :erpc.multicast(Node.list(), Wardrik.MCP, :reconnect, [mcp, reconnected])

    Changes.record_deployment(scope,
      type: type,
      subject: "secrets/" <> name,
      data: %{"secret" => %{"name" => name}, "owner" => owner}
    )

    {:ok, nil}
  end

  # Without keys, Wardrik starts no vault.
  defp sealing(%Wardrik{vault_keys: []}),
    do: {:error, Error.new(:not_supported, "Sealing secrets needs Wardrik's :vault_keys.")}

  defp sealing(_wardrik), do: :ok

  defp unkept(reason),
    do: {:error, Error.new(:unavailable, "The vault didn't keep it: #{inspect(reason)}.")}
end
