defmodule Wardrik.Operations.Owners do
  @moduledoc """
  Operations on the accounts an org or person connects for their agents.
  """

  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Providers
  alias Wardrik.Scope
  alias WardrikCore.Principal
  alias WardrikOAuth.Provider

  @doc """
  Lists the accounts the owner can connect, and whether each is connected.

  These are the OAuth apps the owner signs in with, plus each MCP server that makes its own
  sign-in: their own, their org's for a person, and the deployment's. The nearest app or server
  of a name wins, and a server replaces an app of the same name. Each account is the owner's own,
  whoever added its app or server. See `Wardrik.Owners`.
  """
  @spec connections(Scope.t(), map()) :: {:ok, map()}
  def connections(%Scope{wardrik: wardrik}, %{"owner" => owner}) do
    held = held(wardrik, owner)

    connections =
      for {provider, key} <- offered(wardrik, owner),
          do: %{"provider" => provider, "connected" => key in held}

    {:ok, %{"connections" => connections}}
  end

  @doc "Returns that the account is connected, or where the owner signs in to connect it."
  @spec connect(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def connect(%Scope{wardrik: wardrik}, %{"owner" => owner, "provider" => provider}) do
    with {:ok, key} <- offered(wardrik, owner, provider) do
      if key in held(wardrik, owner),
        do: {:ok, %{"provider" => provider, "connected" => true}},
        else:
          authorizing(wardrik, key, %Principal{id: owner}, %{"provider" => provider}, provider)
    end
  end

  @doc "Disconnects an account. The next call that needs it asks the owner to sign in again."
  @spec disconnect(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def disconnect(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "provider" => provider}) do
    with {:ok, key} <- offered(wardrik, owner, provider) do
      connected = key in held(wardrik, owner)

      if connected do
        :ok = WardrikVault.delete(Wardrik.vault(wardrik), %Principal{id: owner}, key)

        Changes.record_owned(scope,
          type: "secret.removed",
          owner: owner,
          subject: "secrets/" <> key,
          data: %{
            "secret" => %{"name" => key}
          }
        )
      end

      {:ok, %{"provider" => provider, "connected" => connected}}
    end
  end

  defp held(%Wardrik{keys: []}, _owner), do: []
  defp held(wardrik, owner), do: WardrikVault.names(Wardrik.vault(wardrik), %Principal{id: owner})

  # A server's own sign-in is an app named by the server's key, `owner:name`.
  defp offered(wardrik, owner) do
    servers =
      Enum.uniq_by(
        for(
          %Provider{name: key, owner: added_by} <- signs_in(wardrik, owner),
          String.contains?(key, ":"),
          do: {String.replace_prefix(key, added_by <> ":", ""), key}
        ),
        &elem(&1, 0)
      )

    named = Enum.map(servers, &elem(&1, 0))

    providers =
      for %{name: provider} <- Providers.offered(wardrik, owner),
          provider not in named,
          do: {provider, provider}

    providers ++ servers
  end

  defp offered(wardrik, owner, provider) do
    case List.keyfind(offered(wardrik, owner), provider, 0) do
      {^provider, key} -> {:ok, key}
      nil -> {:error, Error.new(:not_found, "There's no account #{provider} to connect.")}
    end
  end

  defp signs_in(%Wardrik{oauth: nil}, _owner), do: []
  defp signs_in(wardrik, owner), do: WardrikOAuth.providers(Wardrik.oauth(wardrik), owner)

  # `key` is the credential, which for a server's own sign-in is its key, not its `name`.
  defp authorizing(wardrik, key, principal, answer, name) do
    case WardrikOAuth.authorize(Wardrik.oauth(wardrik), key, principal) do
      {:ok, url} ->
        {:ok, Map.merge(answer, %{"connected" => false, "authorization" => %{"url" => url}})}

      {:error, reason} ->
        {:error, Error.new(:unavailable, "#{name} can't be signed in to now: #{inspect(reason)}")}
    end
  end
end
