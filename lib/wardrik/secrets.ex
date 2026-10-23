defmodule Wardrik.Secrets do
  @moduledoc false

  alias WardrikCore.Principal

  @spec put(atom() | Wardrik.t(), String.t(), String.t(), binary(), keyword()) ::
          :ok | {:error, term()}
  def put(instance, owner, name, value, opts) do
    with {:ok, wardrik} <- sealing(instance),
         {:ok, _vsn} <-
           WardrikVault.put(Wardrik.vault(wardrik), principal(owner), name, value, opts) do
      recorded(wardrik, "secret.stored", owner, name)
    end
  end

  @spec fetch(atom() | Wardrik.t(), String.t(), String.t()) :: {:ok, binary()} | {:error, term()}
  def fetch(instance, owner, name) do
    with {:ok, wardrik} <- sealing(instance),
         do: WardrikVault.fetch(Wardrik.vault(wardrik), principal(owner), name)
  end

  @spec lookup(atom() | Wardrik.t(), String.t(), String.t()) ::
          {:ok, WardrikVault.kind(), binary(), term()}
          | {:error, term()}
          | {:error, WardrikVault.kind(), term()}
  def lookup(instance, owner, name) do
    with {:ok, wardrik} <- sealing(instance),
         do: WardrikVault.lookup(Wardrik.vault(wardrik), principal(owner), name)
  end

  @spec delete(atom() | Wardrik.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def delete(instance, owner, name) do
    with {:ok, wardrik} <- sealing(instance),
         :ok <- WardrikVault.delete(Wardrik.vault(wardrik), principal(owner), name) do
      recorded(wardrik, "secret.removed", owner, name)
    end
  end

  @spec list(atom() | Wardrik.t()) :: [{String.t(), String.t(), WardrikVault.kind()}]
  def list(instance) do
    case sealing(instance) do
      {:ok, wardrik} -> WardrikVault.list(Wardrik.vault(wardrik))
      {:error, :no_keys} -> []
    end
  end

  @spec list(atom() | Wardrik.t(), String.t()) :: [String.t()]
  def list(instance, owner) do
    case sealing(instance) do
      {:ok, wardrik} -> WardrikVault.names(Wardrik.vault(wardrik), principal(owner))
      {:error, :no_keys} -> []
    end
  end

  defp sealing(instance) do
    case Wardrik.Instance.fetch!(instance) do
      %Wardrik{keys: []} -> {:error, :no_keys}
      wardrik -> {:ok, wardrik}
    end
  end

  defp recorded(wardrik, type, owner, name) do
    change = {type, "secrets/" <> name, %{"secret" => %{"name" => name}, "owner" => owner}}
    WardrikEvents.record(Wardrik.events(wardrik), change)
  end

  defp principal(owner), do: %Principal{id: owner}
end
