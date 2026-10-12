defmodule WardrikOAuth.Connections do
  @moduledoc """
  The `Wardrik.Connections` a deployment names to offer its providers'
  sign-ins as accounts people and orgs connect:

      {Wardrik, connections: WardrikOAuth.Connections}

  A provider is held for an owner where the vault keeps anything under its
  name for them, a sign-in's token or a key someone sealed, read without
  unsealing it; the most specific holder is the one a call would use.
  Connecting starts the provider's sign-in through `WardrikOAuth.hold/3`,
  with nothing parked on it, and forgetting removes what the vault keeps for
  the owner.
  """

  @behaviour Wardrik.Connections

  alias WardrikOAuth.Provider

  @impl Wardrik.Connections
  def list(owner) do
    held = for {kind, holder} <- holders(owner), do: {kind, WardrikVault.names(holder)}

    for provider <- Provider.all() do
      %{
        provider: provider.name,
        held_by: Enum.find_value(held, fn {kind, names} -> provider.name in names && kind end)
      }
    end
  end

  # Whose credentials a call of the owner's would use, the most specific first.
  defp holders({org, _user} = person), do: [person: person, org: org, deployment: nil]
  defp holders(org), do: [org: org, deployment: nil]

  @impl Wardrik.Connections
  def connect(name, owner, by) do
    case Provider.fetch(name) do
      {:ok, provider} -> provider |> WardrikOAuth.hold(owner, by: by) |> connected()
      :error -> {:error, :not_found}
    end
  end

  defp connected({:ok, _credential}), do: {:ok, :held}
  defp connected({:error, :held_as_a_secret}), do: {:ok, :held}
  defp connected({:error, {:authorization_required, link, _owner}}), do: {:ok, link}
  defp connected({:error, reason}), do: {:error, reason}

  @impl Wardrik.Connections
  def disconnect(name, owner) do
    if name in WardrikVault.names(owner),
      do: WardrikOAuth.disconnect(name, owner),
      else: {:error, :not_found}
  end
end
