defmodule Wardrik.Operations.Providers do
  @moduledoc """
  Operations on the OAuth apps an org or person adds for their people to sign in with.

  An owner signs in with the nearest app of a name along `Wardrik.Owners.chain/1`: their own,
  their org's for a person, then the deployment's. An app's client secret is a secret its owner
  keeps, named by reference and read each time it's needed. See `WardrikOAuth`.
  """

  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Scope
  alias WardrikCore.Principal
  alias WardrikOAuth.Provider

  @fields %{
    "issuer" => :issuer,
    "resource" => :resource,
    "authorization_endpoint" => :authorization_endpoint,
    "token_endpoint" => :token_endpoint,
    "client_id" => :client_id,
    "scopes" => :scopes,
    "authorization_params" => :authorization_params
  }
  @choices %{
    "client_auth" => {:client_auth, %{"post" => :post, "basic" => :basic}},
    "flow" => {:flow, %{"browser" => :browser, "device" => :device}}
  }

  @doc "Lists the OAuth apps the owner's people sign in with: their own, then those from further out."
  @spec list(Scope.t(), map()) :: {:ok, map()}
  def list(%Scope{wardrik: wardrik}, %{"owner" => owner}),
    do: {:ok, %{"providers" => Enum.map(offered(wardrik, owner), &answer/1)}}

  @doc "Adds an OAuth app for the owner's people. One further out by the same name is overridden."
  @spec add(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def add(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "name" => name} = input) do
    with :ok <- signs_in(wardrik),
         :ok <- unused(wardrik, owner, name),
         {:ok, opts} <- options(wardrik, owner, Map.drop(input, ["owner", "name"])),
         :ok <- added(wardrik, owner, name, opts) do
      Changes.record_owned(scope, "provider.added", owner, "providers/" <> name, %{
        "provider" => %{"name" => name}
      })

      {:ok, answer(own(wardrik, owner, name))}
    end
  end

  @doc "Removes one of the owner's own OAuth apps. Returns it as it was."
  @spec remove(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def remove(%Scope{wardrik: wardrik} = scope, %{"owner" => owner, "provider" => name}) do
    case own(wardrik, owner, name) do
      %Provider{source: :runtime} = provider ->
        :ok = WardrikOAuth.remove_provider(Wardrik.oauth(wardrik), owner, name)

        Changes.record_owned(scope, "provider.removed", owner, "providers/" <> name, %{
          "provider" => %{"name" => name}
        })

        {:ok, answer(provider)}

      %Provider{source: :config} ->
        {:error,
         Error.new(:invalid_request, "#{name} is an OAuth app the deployment starts with.")}

      nil ->
        {:error, Error.new(:not_found, "#{owner} has no OAuth app #{name}.")}
    end
  end

  @doc """
  Returns the OAuth apps `owner` signs in with, nearest first, leaving out those an MCP server
  made for its own sign-in.
  """
  @spec offered(Wardrik.t(), Wardrik.Owners.t()) :: [Provider.t()]
  def offered(%Wardrik{oauth: nil}, _owner), do: []

  def offered(wardrik, owner) do
    for provider <- WardrikOAuth.providers(Wardrik.oauth(wardrik), owner),
        not String.contains?(provider.name, ":"),
        do: provider
  end

  @doc """
  Maps an OAuth app's JSON fields to `WardrikOAuth.Provider` options, checking `owner` holds the
  client secret it names.
  """
  @spec options(Wardrik.t(), Wardrik.Owners.t(), map()) :: {:ok, keyword()} | {:error, Error.t()}
  def options(wardrik, owner, app) do
    with {:ok, secret} <- client_secret(wardrik, owner, app["client_secret"]) do
      {:ok, Enum.flat_map(app, &option/1) ++ secret}
    end
  end

  defp option({field, value}) when is_map_key(@fields, field), do: [{@fields[field], value}]

  defp option({field, value}) when is_map_key(@choices, field) do
    {option, values} = @choices[field]
    [{option, Map.fetch!(values, value)}]
  end

  defp option(_other), do: []

  defp client_secret(_wardrik, _owner, nil), do: {:ok, []}

  defp client_secret(%Wardrik{keys: []}, _owner, _secret),
    do:
      {:error,
       Error.new(:not_supported, "An app's client secret needs Wardrik to keep credentials.")}

  defp client_secret(wardrik, owner, %{"name" => name}) do
    case WardrikVault.fetch(Wardrik.vault(wardrik), %Principal{id: owner}, name) do
      {:ok, _value} ->
        {:ok, [client_secret: {:secret, name}]}

      {:error, _reason} ->
        {:error, Error.new(:invalid_request, "#{owner} holds no secret #{name}.")}
    end
  end

  @doc """
  Adds `owner`'s OAuth app `name` with `opts`, refusing options WardrikOAuth refuses. An error
  names it as `called`: a server's own app by the server's name.
  """
  @spec added(Wardrik.t(), Wardrik.Owners.t(), String.t(), keyword(), String.t() | nil) ::
          :ok | {:error, Error.t()}
  def added(wardrik, owner, name, opts, called \\ nil) do
    case WardrikOAuth.add_provider(Wardrik.oauth(wardrik), owner, name, opts) do
      :ok ->
        :ok

      {:error, why} ->
        {:error, Error.new(:invalid_request, "#{called || name} can't be signed in with: #{why}")}
    end
  end

  defp signs_in(%Wardrik{oauth: nil}),
    do: {:error, Error.new(:not_supported, "OAuth apps need Wardrik's oauth.")}

  defp signs_in(_wardrik), do: :ok

  defp unused(wardrik, owner, name) do
    if own(wardrik, owner, name) == nil,
      do: :ok,
      else: {:error, Error.new(:conflict, "#{owner} has an OAuth app #{name} already.")}
  end

  defp own(wardrik, owner, name),
    do: Enum.find(offered(wardrik, owner), &(&1.name == name and &1.owner == owner))

  defp answer(%Provider{} = provider) do
    Wardrik.Provider.to_json(%Wardrik.Provider{
      owner: provider.owner,
      name: provider.name,
      source: provider.source,
      issuer: provider.issuer,
      resource: provider.resource,
      authorization_endpoint: provider.authorization_endpoint,
      token_endpoint: provider.token_endpoint,
      client_id: provider.client_id,
      client_secret: secret_name(provider.client_secret),
      client_auth: provider.client_auth,
      scopes: provider.scopes,
      flow: provider.flow,
      authorization_params: params(provider.authorization_params)
    })
  end

  # A secret given in config has no name, and is never answered.
  defp secret_name({:secret, name}), do: name
  defp secret_name(_secret), do: nil

  defp params(params) when params == %{}, do: nil
  defp params(params), do: params
end
