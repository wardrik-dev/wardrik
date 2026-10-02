defmodule WardrikOAuth.Registrations do
  @moduledoc """
  The clients `WardrikOAuth` registered dynamically, kept so each is registered
  once.

  One is kept per provider, issuer and redirect URI, in `Wardrik.Store` under
  `:oauth_clients`. A client registered dynamically is a public one and has
  no secret, so nothing kept here is secret. `WardrikOAuth` forgets a client a
  server answers `invalid_client` for, and registers a new one on the next
  flow.
  """

  alias Wardrik.Store

  @ns :oauth_clients

  @doc "The client registered for `provider` at `issuer` with `redirect_uri`, if one is kept."
  @spec fetch(String.t(), String.t(), String.t()) :: {:ok, map()} | :error
  def fetch(provider, issuer, redirect_uri) do
    case Store.get(@ns, key(provider, issuer, redirect_uri)) do
      %{client_id: client_id, how: :dynamic} = registered when is_binary(client_id) ->
        {:ok, registered}

      _none ->
        :error
    end
  end

  @doc "Keeps a client registered for `provider` at `issuer`."
  @spec put(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put(provider, issuer, %{client_id: client_id, redirect_uri: redirect_uri} = registered) do
    kept = %{client_id: client_id, client_secret: nil, redirect_uri: redirect_uri, how: :dynamic}

    case Store.put(@ns, key(provider, issuer, redirect_uri), Map.merge(registered, kept)) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Forgets the client kept for `provider` at `issuer` with `redirect_uri`,
  where it is the one with `client_id`.
  """
  @spec forget(String.t(), String.t(), String.t(), String.t()) :: :ok
  def forget(provider, issuer, redirect_uri, client_id) do
    key = key(provider, issuer, redirect_uri)

    case Store.lookup(@ns, key) do
      {%{client_id: ^client_id}, _vsn} -> Store.delete(@ns, key)
      _other -> :ok
    end
  end

  defp key(provider, issuer, redirect_uri) do
    digest = :crypto.hash(:sha256, [issuer, "\n", redirect_uri]) |> Base.encode16(case: :lower)
    "#{provider}/#{digest}"
  end
end
