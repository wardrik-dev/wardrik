defmodule WardrikOAuth.Connections do
  @moduledoc """
  The `Wardrik.Connections` a deployment names in its `Wardrik.Host` to
  offer its providers' sign-ins as accounts people and orgs connect, from
  the `WardrikOAuth` settings and the vault it holds:

      Wardrik.Host.new(connections: %WardrikOAuth.Connections{oauth: oauth, vault: vault})

  What holds a provider for an owner is what a call of theirs would find
  under its name, as `WardrikVault.held_by/3` answers without unsealing
  anything: their own, a sign-in's token or a key someone sealed, else one
  the deployment shares.
  Connecting starts the provider's sign-in through `WardrikOAuth.hold/4`,
  with nothing parked on it, and forgetting removes what the vault keeps for
  the owner.
  """

  alias WardrikOAuth.Provider

  @enforce_keys [:oauth, :vault]
  defstruct [:oauth, :vault]

  @type t() :: %__MODULE__{oauth: WardrikOAuth.t(), vault: WardrikVault.t()}

  @doc false
  def list(%__MODULE__{oauth: oauth, vault: vault}, owner) do
    for provider <- Provider.all(oauth) do
      %Wardrik.Connections.Connection{
        provider: provider.name,
        held_by: WardrikVault.held_by(vault, provider.name, owner)
      }
    end
  end

  @doc false
  def connect(%__MODULE__{oauth: oauth, vault: vault}, name, owner, opts) do
    case Provider.fetch(oauth, name, owner) do
      {:ok, provider} ->
        oauth |> WardrikOAuth.hold(provider, owner, vault: vault, by: opts[:by]) |> connected()

      :error ->
        {:error, :not_found}
    end
  end

  defp connected({:ok, _credential}), do: {:ok, :held}
  defp connected({:error, :held_as_a_secret}), do: {:ok, :held}
  defp connected({:error, {:authorization_required, link, _owner}}), do: {:ok, link}
  defp connected({:error, reason}), do: {:error, reason}

  @doc false
  def disconnect(%__MODULE__{vault: vault}, name, owner) do
    if name in WardrikVault.names(vault, owner),
      do: WardrikOAuth.disconnect(vault, name, owner),
      else: {:error, :not_found}
  end
end

defimpl Wardrik.Connections, for: WardrikOAuth.Connections do
  defdelegate list(connections, owner), to: WardrikOAuth.Connections
  defdelegate connect(connections, provider, owner, opts), to: WardrikOAuth.Connections
  defdelegate disconnect(connections, provider, owner), to: WardrikOAuth.Connections
end
