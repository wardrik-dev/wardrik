defmodule WardrikOAuth.Registrations do
  @moduledoc """
  The clients `WardrikOAuth` registered dynamically, kept so each is registered
  once.

  One is kept per provider, issuer and redirect URI, in the store each
  function is handed first, under `:oauth_clients`. A client registered dynamically is a public one and has
  no secret, so nothing kept here is secret. `WardrikOAuth` forgets a client a
  server answers `invalid_client` for, and registers a new one on the next
  flow.
  """

  @ns :oauth_clients

  @doc "The client registered for `provider` at `:issuer` with `:redirect_uri`, if one is kept."
  @spec fetch(WardrikStore.t(), String.t(), issuer: String.t(), redirect_uri: String.t()) ::
          {:ok, map()} | :error
  def fetch(store, provider, opts) do
    case WardrikStore.get(store, @ns, key(provider, opts[:issuer], opts[:redirect_uri])) do
      %{client_id: client_id, how: :dynamic} = registered when is_binary(client_id) ->
        {:ok, registered}

      _none ->
        :error
    end
  end

  @doc "Keeps the client `:registered` for `provider` at `:issuer`."
  @spec put(WardrikStore.t(), String.t(), issuer: String.t(), registered: map()) ::
          :ok | {:error, term()}
  def put(store, provider, opts) do
    %{client_id: client_id, redirect_uri: redirect_uri} =
      registered = Keyword.fetch!(opts, :registered)

    issuer = Keyword.fetch!(opts, :issuer)

    kept = %{client_id: client_id, client_secret: nil, redirect_uri: redirect_uri, how: :dynamic}
    key = key(provider, issuer, redirect_uri)

    case WardrikStore.put(store, @ns, key, Map.merge(registered, kept)) do
      {:ok, _vsn} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Forgets the client kept for `provider` at `:issuer` with
  `:redirect_uri`, where it is the one with `:client_id`.
  """
  @spec forget(WardrikStore.t(), String.t(),
          issuer: String.t(),
          redirect_uri: String.t(),
          client_id: String.t()
        ) :: :ok
  def forget(store, provider, opts) do
    key = key(provider, Keyword.fetch!(opts, :issuer), Keyword.fetch!(opts, :redirect_uri))
    client_id = Keyword.fetch!(opts, :client_id)

    case WardrikStore.lookup(store, @ns, key) do
      {%{client_id: ^client_id}, _vsn} -> WardrikStore.delete(store, @ns, key)
      _other -> :ok
    end
  end

  defp key(provider, issuer, redirect_uri) do
    digest = :crypto.hash(:sha256, [issuer, "\n", redirect_uri]) |> Base.encode16(case: :lower)
    "#{provider}/#{digest}"
  end
end
