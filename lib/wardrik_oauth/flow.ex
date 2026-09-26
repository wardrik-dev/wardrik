defmodule WardrikOAuth.Flow do
  @moduledoc """
  The authorization code flow, with PKCE, against whatever `WardrikOAuth.Metadata`
  found.

      {:ok, metadata} = WardrikOAuth.Metadata.discover("https://mcp.example.com/mcp")
      {:ok, registered} = WardrikOAuth.Flow.register(metadata, client, provider)
      {verifier, challenge} = WardrikOAuth.Flow.pkce()
      url = WardrikOAuth.Flow.authorize_url(metadata, registered, challenge, state: state)
      {:ok, token} = WardrikOAuth.Flow.exchange(metadata, registered, code, verifier)
      {:ok, token} = WardrikOAuth.Flow.refresh(token)

  Every request goes through `WardrikOAuth.Egress`, under the metadata's trust,
  and a refused one answers `{:token_refused, error, description}` with the
  server's OAuth error code, or `http_<status>` where it sent none. A token
  comes back bound to where it came from (`WardrikOAuth.Token.bind/3`), and is
  renewed there.

  ## Registering

  `register/3` picks the least work a server will accept, in this order:

    1. a `:client_id` the deployment configured, for a server that wants one
       registered by hand
    2. the client's own metadata document URL, where the server supports Client
       ID Metadata Documents
    3. dynamic client registration, where it has an endpoint for it, asking for
     the device grant too where the server offers it

  A server offering none of the three cannot be reached without a `:client_id`,
  and says so. A `:client_secret` is sent only to an issuer the deployment
  named: a provider with one and no `:issuer` is refused. A client registered
  dynamically is a public one, and keeps no secret the server hands back.
  """

  alias WardrikOAuth.Client
  alias WardrikOAuth.Egress
  alias WardrikOAuth.Metadata
  alias WardrikOAuth.Provider
  alias WardrikOAuth.Token

  @typedoc "A client identity a particular server will accept."
  @type registered() :: %{
          client_id: String.t(),
          client_secret: String.t() | nil,
          redirect_uri: String.t(),
          how: :static | :cimd | :dynamic
        }

  @doc "A PKCE verifier and the challenge derived from it."
  @spec pkce() :: {verifier :: String.t(), challenge :: String.t()}
  def pkce do
    verifier = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    challenge = :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false)

    {verifier, challenge}
  end

  @doc "A value to correlate a callback with the flow that started it."
  @spec state() :: String.t()
  def state, do: 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc """
  Finds a client identity this server will accept.

  `:known` is a client registered dynamically before, used where this one
  would register dynamically again.
  """
  @spec register(Metadata.t(), Client.t(), Provider.t(), keyword()) ::
          {:ok, registered()} | {:error, term()}
  def register(%Metadata{} = metadata, %Client{} = client, %Provider{} = provider, opts \\ []) do
    cond do
      provider.client_secret && metadata.trust != :operator ->
        {:error, {:client_secret_needs_issuer, provider.name}}

      provider.client_id ->
        {:ok, identity(provider.client_id, provider, client, :static)}

      metadata.cimd_supported? and client.document_url ->
        cimd(client, provider)

      known = Keyword.get(opts, :known) ->
        {:ok, known}

      metadata.registration_endpoint ->
        dynamic(metadata, client, provider)

      true ->
        {:error, {:no_registration, metadata.issuer}}
    end
  end

  @doc """
  The scopes a flow asks for: the provider's own, else the ones the
  resource's metadata names, else none, and the server decides.
  """
  @spec scopes(Provider.t(), Metadata.t()) :: [String.t()]
  def scopes(%Provider{scopes: [_ | _] = scopes}, %Metadata{}), do: scopes
  def scopes(%Provider{}, %Metadata{resource_scopes: scopes}), do: scopes

  @doc """
  Where to send the user.

  `:state` correlates the answer, `:scopes` overrides what the provider asks
  for, and the resource indicator is sent where the metadata names one, so the
  token comes back bound to the server it is for.
  """
  @spec authorize_url(Metadata.t(), registered(), String.t(), keyword()) :: String.t()
  def authorize_url(%Metadata{} = metadata, registered, challenge, opts) do
    params =
      %{
        "response_type" => "code",
        "client_id" => registered.client_id,
        "redirect_uri" => registered.redirect_uri,
        "code_challenge" => challenge,
        "code_challenge_method" => "S256",
        "state" => Keyword.fetch!(opts, :state)
      }
      |> put_present("scope", opts |> Keyword.get(:scopes, []) |> Enum.join(" "))
      |> put_present("resource", metadata.resource)

    metadata.authorization_endpoint
    |> URI.parse()
    |> then(&%{&1 | query: URI.encode_query(Map.merge(query(&1), params))})
    |> URI.to_string()
  end

  @doc "Trades an authorization code for a token."
  @spec exchange(Metadata.t(), registered(), String.t(), String.t(), keyword()) ::
          {:ok, Token.t()} | {:error, term()}
  def exchange(%Metadata{} = metadata, registered, code, verifier, opts \\ []) do
    %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => registered.redirect_uri,
      "client_id" => registered.client_id,
      "code_verifier" => verifier
    }
    |> put_present("client_secret", registered.client_secret)
    |> put_present("resource", metadata.resource)
    |> post(metadata.token_endpoint, metadata.trust, opts)
    |> case do
      {:ok, token} -> {:ok, Token.bind(token, metadata, registered)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Renews a token without the user, at the token endpoint it came from, as
  the client it was issued to.

  Options:

    * `:trust` - the `WardrikOAuth.Egress` trust of the token endpoint,
      `:discovered` unless given
    * `:client_secret` - sent where the client has one
    * `:req_options` - merged into the request
  """
  @spec refresh(Token.t(), keyword()) :: {:ok, Token.t()} | {:error, term()}
  def refresh(%Token{} = token, opts \\ []) do
    if Token.renewable?(token) do
      %{
        "grant_type" => "refresh_token",
        "refresh_token" => token.refresh_token,
        "client_id" => token.client_id
      }
      |> put_present("client_secret", Keyword.get(opts, :client_secret))
      |> put_present("resource", token.resource)
      |> post(token.token_endpoint, Keyword.get(opts, :trust, :discovered), opts)
      |> case do
        {:ok, fresh} -> {:ok, Token.renewed(token, fresh)}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_renewable}
    end
  end

  defp cimd(%Client{} = client, %Provider{} = provider) do
    {:ok, identity(client.document_url, provider, client, :cimd)}
  end

  defp dynamic(%Metadata{} = metadata, %Client{} = client, %Provider{} = provider) do
    body =
      client
      |> Client.registration()
      |> put_present("scope", provider |> scopes(metadata) |> Enum.join(" "))
      |> device_grant(metadata)

    with {:ok, options} <-
           Egress.options(
             metadata.registration_endpoint,
             metadata.trust,
             [json: body] ++ client.req_options
           ) do
      case Req.post(options) do
        {:ok, %Req.Response{status: status, body: %{"client_id" => id}}}
        when status in [200, 201] and is_binary(id) ->
          {:ok, %{identity(id, provider, client, :dynamic) | client_secret: nil}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {error, description} = Token.refusal(body)
          {:error, {:registration_refused, error || "http_#{status}", description}}

        {:error, reason} ->
          {:error, {:registration_unreachable, reason}}
      end
    end
  end

  # A client registered where the server offers the device grant may use it,
  # as well as the code flow.
  defp device_grant(body, %Metadata{} = metadata) do
    if WardrikOAuth.Device.offered?(metadata),
      do: Map.update!(body, "grant_types", &(&1 ++ [WardrikOAuth.Device.grant()])),
      else: body
  end

  defp identity(client_id, %Provider{} = provider, %Client{} = client, how) do
    %{
      client_id: client_id,
      client_secret: provider.client_secret,
      redirect_uri: provider.redirect_uri || client.redirect_uri,
      how: how
    }
  end

  defp post(form, endpoint, trust, opts) do
    request =
      [form: form, headers: [accept: "application/json"]] ++ Keyword.get(opts, :req_options, [])

    with {:ok, options} <- Egress.options(endpoint, trust, request) do
      case Req.post(options) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
          Token.from_response(body)

        {:ok, %Req.Response{status: status, body: body}} ->
          {error, description} = Token.refusal(body)
          {:error, {:token_refused, error || "http_#{status}", description}}

        {:error, reason} ->
          {:error, {:token_unreachable, reason}}
      end
    end
  end

  defp query(%URI{query: nil}), do: %{}
  defp query(%URI{query: query}), do: URI.decode_query(query)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
