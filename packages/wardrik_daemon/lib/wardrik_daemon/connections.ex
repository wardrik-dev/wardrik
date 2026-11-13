defmodule WardrikDaemon.Connections do
  @moduledoc """
  The accounts a person connects for their agents, served at `/v1/connections`.

      wardrik connection ls
      wardrik connection connect linear

    * Each OAuth app and each MCP server's own sign-in is offered, by name.
    * Each person sees and changes only their own accounts.
    * A device sign-in finishes at the provider. A browser sign-in finishes when the person
      sends the code the callback page shows. See `WardrikDaemon.Pairings`.
    * Forgetting one records `secret.removed` in the audit.
  """

  alias Wardrik.Error
  alias Wardrik.OAuth.Apps
  alias WardrikCore.Principal
  alias WardrikDaemon.Pairings

  @doc """
  Lists the accounts `principal` can connect.

  Each entry has `"provider"`, `"connected"` and `"signing_in"`, which is `true` while a
  sign-in is under way.
  """
  @spec list(WardrikDaemon.Settings.daemon(), Principal.t()) :: [map()]
  def list(%{wardrik: wardrik} = daemon, %Principal{} = principal) do
    held = held(daemon, principal)

    for {provider, credential} <- offered(daemon, principal) do
      %{
        "provider" => provider,
        "connected" => credential in held,
        "signing_in" => Wardrik.signing_in?(wardrik, credential, principal)
      }
    end
  end

  @doc """
  Starts `principal`'s sign-in to `provider`.

  Returns that it's connected already, or the URL to sign in at, with a code for a device sign-in.
  """
  @spec connect(WardrikDaemon.Settings.daemon(), Principal.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def connect(daemon, %Principal{} = principal, provider) do
    with {:ok, credential} <- credential(daemon, principal, provider) do
      if credential in held(daemon, principal),
        do: {:ok, %{"provider" => provider, "connected" => true}},
        else: authorizing(daemon, {principal, credential}, provider)
    end
  end

  @doc """
  Forgets `principal`'s account `provider`. The next call that needs it asks them to sign in again.

  Returns `:not_found` where they hold no such account.
  """
  @spec disconnect(WardrikDaemon.Settings.daemon(), Principal.t(), String.t()) ::
          :ok | {:error, Error.t()}
  def disconnect(%{wardrik: wardrik} = daemon, %Principal{id: id} = principal, provider) do
    with {:ok, credential} <- credential(daemon, principal, provider) do
      if credential in held(daemon, principal),
        do: forgotten(Wardrik.as(wardrik, principal), %{"owner" => id, "name" => credential}),
        else: {:error, Error.new(:not_found, "You have no #{provider} account connected.")}
    end
  end

  defp forgotten(scope, secret) do
    with {:ok, nil} <- Wardrik.run(scope, "secrets.delete", secret), do: :ok
  end

  @doc """
  Finishes `principal`'s browser sign-in to `provider` with the `code` its page showed.

  Every wrong code fails the same way. After 5, the sign-in ends.
  """
  @spec pair(WardrikDaemon.Settings.daemon(), Principal.t(), {String.t(), String.t()}) ::
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
  Takes a browser sign-in's callback `params`. Returns the code to show, or `{:error, reason}`.
  """
  @spec called_back(WardrikDaemon.Settings.daemon(), map()) ::
          {:ok, %{provider: String.t(), code: String.t()}} | {:error, :declined | :unknown}
  def called_back(daemon, params), do: called_back(daemon, params, :adopt)

  defp called_back(%{wardrik: wardrik} = daemon, params, adopt) do
    case {Pairings.called_back(Pairings.name(wardrik), params), adopt} do
      {{:ok, code, sign_in}, _adopt} ->
        {:ok, %{provider: sign_in.provider, code: code}}

      {{:declined, sign_in}, _adopt} ->
        _ended = end_flow(wardrik, sign_in.principal, params)
        {:error, :declined}

      {:error, :adopt} ->
        if adopted?(daemon, params),
          do: called_back(daemon, params, :adopted),
          else: {:error, :unknown}

      {:error, :adopted} ->
        {:error, :unknown}
    end
  end

  # An agent waiting on a sign-in started it, not `wardrik connection connect`, so it's paired
  # when its callback comes, with the person it's for.
  defp adopted?(%{wardrik: wardrik} = daemon, %{"state" => state}) when is_binary(state) do
    case Wardrik.started_sign_in(wardrik, state) do
      {:ok, %{provider: credential, principal: principal}} ->
        sign_in = %{principal: principal, provider: provider(daemon, principal, credential)}

        :ok =
          Pairings.started(
            Pairings.name(wardrik),
            state,
            Map.put(sign_in, :credential, credential)
          )

        true

      :error ->
        false
    end
  end

  defp adopted?(_daemon, _params), do: false

  defp provider(daemon, principal, credential) do
    case List.keyfind(offered(daemon, principal), credential, 1) do
      {provider, ^credential} -> provider
      nil -> credential
    end
  end

  defp finished(wardrik, params, principal, provider) do
    case Wardrik.finish_sign_in(wardrik, params, as: principal) do
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
      Wardrik.finish_sign_in(wardrik, %{"state" => state, "error" => "access_denied"},
        as: principal
      )

  defp unpaired(provider),
    do:
      Error.new(
        :invalid_request,
        "That code doesn't match a #{provider} sign-in you started. Check it, or connect again."
      )

  # Each app the person may sign in with, by the name they know it by, and the reference a
  # sign-in to it goes by. A server's own sign-in goes by the server's name.
  defp offered(%{wardrik: wardrik}, principal) do
    wardrik
    |> Wardrik.Instance.fetch!()
    |> Apps.offered(principal)
    |> Enum.map(&{Apps.shown(&1), Apps.reference(&1)})
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp credential(daemon, principal, provider) do
    case List.keyfind(offered(daemon, principal), provider, 0) do
      {^provider, credential} -> {:ok, credential}
      nil -> {:error, Error.new(:not_found, "There's no account #{provider} to connect.")}
    end
  end

  defp held(%{wardrik: wardrik}, principal) do
    wardrik |> Wardrik.Instance.fetch!() |> Wardrik.vault() |> Wardrik.Vault.names(principal)
  end

  defp authorizing(%{wardrik: wardrik}, {principal, credential}, provider) do
    case Wardrik.sign_in(wardrik, credential, principal) do
      {:ok, started} ->
        authorization = Map.new(started, fn {key, value} -> {Atom.to_string(key), value} end)
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
end
