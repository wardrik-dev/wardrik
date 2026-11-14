defmodule Wardrik.Operations.Connections do
  @moduledoc false

  # The accounts a principal connects for their agents: each OAuth app they may sign in with, as
  # `Wardrik.OAuth.Apps.offered/2` picks them, by the name they know it by. Each sees and changes
  # only their own.

  alias Wardrik.Error
  alias Wardrik.OAuth.Apps
  alias Wardrik.Operations.Secrets
  alias Wardrik.Scope
  alias WardrikCore.Principal

  @doc "Lists the accounts the caller can connect, whether they hold each, and any sign-in under way."
  @spec list(Scope.t(), map()) :: {:ok, map()}
  def list(%Scope{wardrik: wardrik, principal: principal}, _input) do
    offered = offered(wardrik, principal)

    # Sign-ins under way go first: a sign-in keeps its grant before it ends, so one that ends
    # between the two reads shows as held.
    signing_in =
      for {_provider, credential} <- offered,
          Wardrik.signing_in?(wardrik, credential, principal),
          do: credential

    held = held(wardrik, principal)

    connections =
      for {provider, credential} <- offered do
        %{
          "provider" => provider,
          "connected" => credential in held,
          "signing_in" => credential in signing_in
        }
      end

    {:ok, %{"connections" => connections}}
  end

  @doc "Starts the caller's sign-in to `provider`, or says they hold it already."
  @spec connect(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def connect(%Scope{wardrik: wardrik, principal: principal}, %{"provider" => provider}) do
    with {:ok, credential} <- credential(wardrik, principal, provider) do
      if credential in held(wardrik, principal),
        do: {:ok, %{"provider" => provider, "connected" => true}},
        else: authorizing(wardrik, {principal, credential}, provider)
    end
  end

  @doc "Forgets the caller's account `provider`. The next call that needs it asks them again."
  @spec disconnect(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def disconnect(%Scope{wardrik: wardrik, principal: principal} = scope, %{"provider" => provider}) do
    with {:ok, credential} <- credential(wardrik, principal, provider) do
      if credential in held(wardrik, principal),
        do: Secrets.delete(scope, %{"owner" => principal.id, "name" => credential}),
        else: {:error, Error.new(:not_found, "You have no #{provider} account connected.")}
    end
  end

  @doc """
  Returns the reference a sign-in of `principal` to `provider` goes by, the name they know an app
  by, or `not_found`.
  """
  @spec credential(Wardrik.t(), Principal.t(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def credential(wardrik, principal, provider) do
    offered = offered(wardrik, principal)

    case List.keyfind(offered, provider, 0) do
      {^provider, credential} -> {:ok, credential}
      nil -> {:error, Error.new(:not_found, "There's no account #{provider} to connect.")}
    end
  end

  @doc "Returns the name `principal` knows the app a sign-in to `credential` uses by."
  @spec provider(Wardrik.t(), Principal.t(), String.t()) :: String.t()
  def provider(wardrik, principal, credential) do
    offered = offered(wardrik, principal)

    case List.keyfind(offered, credential, 1) do
      {provider, ^credential} -> provider
      nil -> credential
    end
  end

  # Each app by the name a person knows it by, and the reference a sign-in to it goes by. A
  # server's own sign-in goes by the server's name.
  defp offered(wardrik, principal) do
    wardrik
    |> Apps.offered(principal)
    |> Enum.map(&{Apps.shown(&1), Apps.reference(&1)})
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp held(%Wardrik{vault_keys: []}, _principal), do: []

  defp held(wardrik, principal) do
    wardrik
    |> Wardrik.vault()
    |> Wardrik.Vault.names(principal)
  end

  defp authorizing(%Wardrik{oauth: nil}, _sign_in, provider),
    do: {:error, Error.new(:not_supported, "Connecting #{provider} needs Wardrik's :oauth.")}

  defp authorizing(wardrik, {principal, credential}, provider) do
    case Wardrik.sign_in(wardrik, credential, principal) do
      {:ok, started} ->
        authorization = Map.new(started, fn {key, value} -> {Atom.to_string(key), value} end)
        {:ok, %{"provider" => provider, "connected" => false, "authorization" => authorization}}

      {:error, reason} ->
        {:error,
         Error.new(:unavailable, "#{provider} can't be signed in to now: #{inspect(reason)}")}
    end
  end
end
