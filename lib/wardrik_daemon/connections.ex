defmodule WardrikDaemon.Connections do
  @moduledoc """
  The accounts a principal connects for their agents. `WardrikDaemon.HTTP` serves the caller's
  own at `/v1/connections`, and `wardrik connection` reaches them there.

  A principal is offered each OAuth app they sign in with (see `WardrikDaemon.OAuthApps`), and
  each MCP server's own sign-in, by the server's name. A server's sign-in comes ahead of an app
  of the same name. Each account is the principal's own: listing, connecting and forgetting one
  reaches only their grants. Forgetting one records `secret.removed` in the audit.
  """

  alias Wardrik.Error
  alias WardrikCore.Principal
  alias WardrikDaemon.OAuthApps
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
    oauth = wardrik |> Wardrik.Instance.fetch!() |> Wardrik.oauth()

    case WardrikOAuth.authorize(oauth, credential, principal) do
      {:ok, url} ->
        authorization = authorization(oauth, url)
        {:ok, %{"provider" => provider, "connected" => false, "authorization" => authorization}}

      {:error, reason} ->
        {:error,
         Error.new(:unavailable, "#{provider} can't be signed in to now: #{inspect(reason)}")}
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
