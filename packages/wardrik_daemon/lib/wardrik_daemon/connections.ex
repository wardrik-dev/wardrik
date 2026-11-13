defmodule WardrikDaemon.Connections do
  @moduledoc """
  Finishes a person's browser sign-in from the terminal or the dashboard, by the code the
  callback page shows. Connections themselves are Wardrik's `connections.*` operations.

      wardrik connection connect linear

    * A device sign-in finishes at the provider. A browser sign-in finishes when the person
      sends the code the callback page shows. See `WardrikDaemon.Pairings`.
    * A sign-in is paired as its callback comes, with the person it's for, whoever started it.
  """

  alias Wardrik.Error
  alias Wardrik.Operations.Connections
  alias WardrikCore.Principal
  alias WardrikDaemon.Pairings

  @doc """
  Finishes `principal`'s browser sign-in to `provider` with the `code` its page showed.

  Every wrong code fails the same way. After 5, the sign-in ends.
  """
  @spec pair(WardrikDaemon.Settings.daemon(), Principal.t(), {String.t(), String.t()}) ::
          {:ok, map()} | {:error, Error.t()}
  def pair(%{wardrik: wardrik} = daemon, %Principal{} = principal, {provider, code}) do
    with {:ok, credential} <- credential(daemon, principal, provider) do
      pairings = Pairings.name(wardrik)

      case Pairings.pair(pairings, {principal, credential}, code) do
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
    pairings = Pairings.name(wardrik)

    case {Pairings.called_back(pairings, params), adopt} do
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

        pairings = Pairings.name(wardrik)
        :ok = Pairings.started(pairings, state, Map.put(sign_in, :credential, credential))

        true

      :error ->
        false
    end
  end

  defp adopted?(_daemon, _params), do: false

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

  defp credential(%{wardrik: wardrik}, principal, provider) do
    wardrik
    |> Wardrik.Instance.fetch!()
    |> Connections.credential(principal, provider)
  end

  defp provider(%{wardrik: wardrik}, principal, credential) do
    wardrik
    |> Wardrik.Instance.fetch!()
    |> Connections.provider(principal, credential)
  end
end
