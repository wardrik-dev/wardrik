defmodule WardrikDaemon.Connections do
  @moduledoc """
  The accounts a principal connects for their agents. `WardrikDaemon.HTTP` serves the caller's
  own at `/v1/connections`, and `wardrik connection` reaches them there.

  A principal is offered each OAuth app they sign in with (see `WardrikDaemon.OAuthApps`), and
  each MCP server's own sign-in, by the server's name. A server's sign-in comes ahead of an app
  of the same name. Each account is the principal's own: listing, connecting and forgetting one
  reaches only their grants. Forgetting one records `secret.removed` in the audit.

  A device sign-in finishes at the provider. A browser sign-in finishes once its principal sends
  the code the callback page shows, as `WardrikDaemon.Pairings` pairs them. The callback alone
  connects nothing.
  """

  alias Wardrik.Error
  alias WardrikCore.Principal
  alias WardrikDaemon.OAuthApps
  alias WardrikDaemon.Pairings
  alias WardrikDaemon.Secrets
  alias WardrikDaemon.Servers

  @doc "Lists the accounts `principal` can connect, and whether each is connected."
  @spec list(Servers.daemon(), Principal.t()) :: [map()]
  def list(daemon, %Principal{} = principal) do
    held = held(daemon, principal)

    for {provider, credential} <- offered(daemon, principal),
        do: %{"provider" => provider, "connected" => credential in held}
  end

  @doc """
  Starts `principal`'s sign-in to `provider`. Returns that it's connected already, or where they
  sign in: the URL, and for a device sign-in the code to enter there.
  """
  @spec connect(Servers.daemon(), Principal.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def connect(daemon, %Principal{} = principal, provider) do
    with {:ok, credential} <- credential(daemon, principal, provider) do
      if credential in held(daemon, principal),
        do: {:ok, %{"provider" => provider, "connected" => true}},
        else: authorizing(daemon, {principal, credential}, provider)
    end
  end

  @doc "Forgets `principal`'s account `provider`, as `actor`. The next call that needs it asks them to sign in again."
  @spec disconnect(Servers.daemon(), Principal.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def disconnect(%{wardrik: wardrik} = daemon, %Principal{id: id} = principal, provider) do
    with {:ok, credential} <- credential(daemon, principal, provider) do
      connected = credential in held(daemon, principal)
      if connected, do: :ok = Secrets.delete(wardrik, {id, credential}, principal)
      {:ok, %{"provider" => provider, "connected" => connected}}
    end
  end

  @doc """
  Finishes `principal`'s browser sign-in to `provider` with the `code` its callback page showed.

  A code that isn't that sign-in's own, used, expired or wrong, fails the same way, so it says
  nothing of whose it was. After 5 wrong codes the sign-in is abandoned.
  """
  @spec pair(Servers.daemon(), Principal.t(), {String.t(), String.t()}) ::
          {:ok, map()} | {:error, Error.t()}
  def pair(%{wardrik: wardrik} = daemon, %Principal{} = principal, {provider, code}) do
    with {:ok, credential} <- credential(daemon, principal, provider) do
      case Pairings.pair(Pairings.name(wardrik), {principal, credential}, code) do
        {:ok, params} -> finished(wardrik, params, principal, provider)
        {:error, :mismatch} -> {:error, unpaired(provider)}
        {:error, {:ended, sign_in, state}} -> ended(wardrik, sign_in, state, provider)
      end
    end
  end

  @doc """
  Takes a browser sign-in's callback `params`. Returns the code its principal sends to finish it,
  or `{:error, reason}` where it ends here.
  """
  @spec called_back(Servers.daemon(), map()) ::
          {:ok, %{provider: String.t(), code: String.t()}} | {:error, :declined | :unknown}
  def called_back(%{wardrik: wardrik}, params) do
    case Pairings.called_back(Pairings.name(wardrik), params) do
      {:ok, code, sign_in} ->
        {:ok, %{provider: sign_in.provider, code: code}}

      {:declined, sign_in} ->
        _ended = end_flow(wardrik, sign_in.principal, params)
        {:error, :declined}

      :error ->
        {:error, :unknown}
    end
  end

  defp finished(wardrik, params, principal, provider) do
    case WardrikOAuth.finish(oauth(wardrik), params, as: principal) do
      {:ok, _granted} ->
        {:ok, %{"provider" => provider, "connected" => true}}

      {:error, reason} ->
        {:error,
         Error.new(
           :unavailable,
           "#{provider} didn't finish signing you in: #{inspect(reason)}. Connect again."
         )}
    end
  end

  # An abandoned or expired sign-in is ended as the principal who started it, so its link is dead.
  defp ended(wardrik, sign_in, state, provider) do
    _ended = end_flow(wardrik, sign_in.principal, %{"state" => state})
    {:error, Error.new(:invalid_request, "#{unpaired(provider).message} This sign-in has ended.")}
  end

  defp end_flow(wardrik, principal, %{"state" => state}),
    do:
      WardrikOAuth.finish(oauth(wardrik), %{"state" => state, "error" => "access_denied"},
        as: principal
      )

  defp unpaired(provider),
    do:
      Error.new(
        :invalid_request,
        "That code doesn't match a #{provider} sign-in you started. Check it, or connect again."
      )

  defp oauth(wardrik), do: wardrik |> Wardrik.Instance.fetch!() |> Wardrik.oauth()

  # A server's own sign-in is an app named by its key, `owner:name`.
  defp offered(daemon, %Principal{id: id}) do
    {servers, apps} =
      daemon
      |> OAuthApps.reached(id)
      |> Enum.split_with(&String.contains?(&1.name, ":"))

    servers =
      Enum.uniq_by(
        for(
          app <- servers,
          do: {String.replace_prefix(app.name, app.owner <> ":", ""), app.name}
        ),
        &elem(&1, 0)
      )

    named = Enum.map(servers, &elem(&1, 0))
    for(app <- apps, app.name not in named, do: {app.name, app.name}) ++ servers
  end

  defp credential(daemon, principal, provider) do
    case List.keyfind(offered(daemon, principal), provider, 0) do
      {^provider, credential} -> {:ok, credential}
      nil -> {:error, Error.new(:not_found, "There's no account #{provider} to connect.")}
    end
  end

  defp held(%{wardrik: wardrik}, principal) do
    wardrik |> Wardrik.Instance.fetch!() |> Wardrik.vault() |> WardrikVault.names(principal)
  end

  defp authorizing(%{wardrik: wardrik}, {principal, credential}, provider) do
    oauth = oauth(wardrik)

    case WardrikOAuth.authorize(oauth, credential, principal) do
      {:ok, url} ->
        authorization = authorization(oauth, url)
        sign_in = %{principal: principal, provider: provider, credential: credential}
        :ok = paired_later(wardrik, authorization, sign_in)
        {:ok, %{"provider" => provider, "connected" => false, "authorization" => authorization}}

      {:error, reason} ->
        {:error,
         Error.new(:unavailable, "#{provider} can't be signed in to now: #{inspect(reason)}")}
    end
  end

  # A browser sign-in comes back with the state its URL carries. A device sign-in never does.
  defp paired_later(_wardrik, %{"code" => _device}, _sign_in), do: :ok

  defp paired_later(wardrik, %{"url" => url}, sign_in) do
    case URI.decode_query(URI.parse(url).query || "") do
      %{"state" => state} -> Pairings.started(Pairings.name(wardrik), state, sign_in)
      _stateless -> :ok
    end
  end

  # A device sign-in's URL is its page on the daemon, which names the flow.
  defp authorization(oauth, url) do
    with [_page, id] <- String.split(url, "/device/", parts: 2),
         {:ok, %{user_code: code, verification_uri: uri}} <- WardrikOAuth.flow(oauth, id) do
      %{"url" => uri, "code" => code}
    else
      _browser -> %{"url" => url}
    end
  end
end
