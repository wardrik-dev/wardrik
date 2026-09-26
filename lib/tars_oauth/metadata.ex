defmodule TarsOAuth.Metadata do
  @moduledoc """
  What a server says about how to authorize against it, found rather than
  configured.

  `discover/2` walks the chain the MCP authorization spec describes:

      the resource                      https://mcp.example.com/mcp
        -> protected resource metadata  /.well-known/oauth-protected-resource  (RFC 9728)
        -> the authorization server     /.well-known/oauth-authorization-server (RFC 8414)
        -> or, failing that             /.well-known/openid-configuration

  A deployment that knows the issuer already skips the first leg with
  `:issuer`.

  What a server says is checked before it is used:

    * the resource metadata names the resource it was asked about, a trailing
      `/` aside, and an authorization server
    * the authorization server's metadata names the issuer it was asked
      about, exactly
    * every endpoint is a URL `TarsOAuth.Egress` allows under the metadata's
      `:trust`: `:operator` where the deployment named the issuer, and
      `:discovered` where the resource's metadata did

  `:client_id_metadata_document_supported` is what decides whether this
  deployment can present a URL as its `client_id` instead of registering, and
  `:device_authorization_endpoint` whether a user can authorize from another
  device; see `TarsOAuth.Device`. `:code_challenge_methods_supported` must
  name `S256` for a browser flow, and
  `:authorization_response_iss_parameter_supported` says a callback carries
  `iss` (RFC 9207). `:resource_scopes` are the scopes the resource's metadata
  names, what a provider that names none asks for.
  """

  alias TarsOAuth.Egress

  @enforce_keys [:issuer, :authorization_endpoint, :token_endpoint]
  defstruct [
    :issuer,
    :authorization_endpoint,
    :token_endpoint,
    :registration_endpoint,
    :device_authorization_endpoint,
    :resource,
    trust: :discovered,
    scopes_supported: [],
    resource_scopes: [],
    code_challenge_methods_supported: [],
    cimd_supported?: false,
    iss_supported?: false
  ]

  @typedoc "An authorization server, as it describes itself."
  @type t() :: %__MODULE__{
          issuer: String.t(),
          authorization_endpoint: String.t(),
          token_endpoint: String.t(),
          registration_endpoint: String.t() | nil,
          device_authorization_endpoint: String.t() | nil,
          resource: String.t() | nil,
          trust: Egress.trust(),
          scopes_supported: [String.t()],
          resource_scopes: [String.t()],
          code_challenge_methods_supported: [String.t()],
          cimd_supported?: boolean(),
          iss_supported?: boolean()
        }

  @resource_metadata "/.well-known/oauth-protected-resource"
  @as_metadata "/.well-known/oauth-authorization-server"
  @oidc_metadata "/.well-known/openid-configuration"

  @endpoints ~w(authorization_endpoint token_endpoint registration_endpoint device_authorization_endpoint)

  @doc """
  Finds the authorization server behind `resource`.

  Options:

    * `:issuer` - skip the resource leg and ask this issuer directly
    * `:req_options` - merged into every request
  """
  @spec discover(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def discover(resource, opts \\ []) when is_binary(resource) do
    with :ok <- Egress.check(resource, :operator),
         {:ok, issuer, trust, scopes} <- issuer(resource, opts),
         {:ok, metadata} <- authorization_server(issuer, trust, opts) do
      {:ok, %{metadata | resource: resource, trust: trust, resource_scopes: scopes}}
    end
  end

  @doc "Whether the server takes a PKCE challenge made with SHA-256."
  @spec pkce?(t()) :: boolean()
  def pkce?(%__MODULE__{code_challenge_methods_supported: methods}), do: "S256" in methods

  @doc """
  The URL of the resource metadata a `WWW-Authenticate` header points at.

  What a 401 from an MCP server carries, and the shortest way to the
  authorization server when a resource publishes no metadata of its own.
  """
  @spec from_challenge(String.t()) :: {:ok, String.t()} | :error
  def from_challenge(header) when is_binary(header) do
    case Regex.run(~r/resource_metadata="([^"]+)"/, header) do
      [_match, url] -> {:ok, url}
      nil -> :error
    end
  end

  defp issuer(resource, opts) do
    case Keyword.get(opts, :issuer) do
      nil -> from_resource(resource, opts)
      issuer -> {:ok, issuer, :operator, []}
    end
  end

  defp from_resource(resource, opts) do
    case get(well_known(resource, @resource_metadata), :operator, opts) do
      {:ok, %{"resource" => named, "authorization_servers" => [issuer | _rest]} = body}
      when is_binary(named) and is_binary(issuer) ->
        if same_resource?(named, resource),
          do: {:ok, issuer, :discovered, strings(body["scopes_supported"])},
          else: {:error, {:resource_mismatch, resource, named}}

      {:ok, _body} ->
        {:error, {:no_authorization_server, resource}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp same_resource?(named, resource),
    do: String.trim_trailing(named, "/") == String.trim_trailing(resource, "/")

  defp authorization_server(issuer, trust, opts) do
    with :ok <- Egress.check(issuer, trust) do
      case get(well_known(issuer, @as_metadata), trust, opts) do
        {:ok, body} -> read(body, issuer, trust)
        {:error, _reason} -> openid_configuration(issuer, trust, opts)
      end
    end
  end

  defp openid_configuration(issuer, trust, opts) do
    with {:ok, body} <- get(well_known(issuer, @oidc_metadata), trust, opts),
         do: read(body, issuer, trust)
  end

  defp read(%{"issuer" => issuer} = body, issuer, trust) do
    with %{"authorization_endpoint" => authorize, "token_endpoint" => token}
         when is_binary(authorize) and is_binary(token) <- body,
         :ok <- endpoints(body, trust) do
      {:ok,
       %__MODULE__{
         issuer: issuer,
         authorization_endpoint: authorize,
         token_endpoint: token,
         registration_endpoint: body["registration_endpoint"],
         device_authorization_endpoint: body["device_authorization_endpoint"],
         scopes_supported: strings(body["scopes_supported"]),
         code_challenge_methods_supported: strings(body["code_challenge_methods_supported"]),
         cimd_supported?: body["client_id_metadata_document_supported"] == true,
         iss_supported?: body["authorization_response_iss_parameter_supported"] == true
       }}
    else
      {:error, reason} -> {:error, reason}
      _incomplete -> {:error, {:metadata_incomplete, issuer}}
    end
  end

  defp read(%{"issuer" => named}, issuer, _trust) when is_binary(named),
    do: {:error, {:issuer_mismatch, issuer, named}}

  defp read(_body, issuer, _trust), do: {:error, {:metadata_incomplete, issuer}}

  defp endpoints(body, trust) do
    @endpoints
    |> Enum.map(&body[&1])
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(:ok, &refused_endpoint(&1, trust, body["issuer"]))
  end

  defp refused_endpoint(url, trust, _issuer) when is_binary(url) do
    case Egress.check(url, trust) do
      :ok -> nil
      refused -> refused
    end
  end

  defp refused_endpoint(_url, _trust, issuer), do: {:error, {:metadata_incomplete, issuer}}

  defp strings(values) when is_list(values), do: Enum.filter(values, &is_binary/1)
  defp strings(_other), do: []

  # RFC 9728 puts the resource's own path after the well-known segment, so one
  # host can serve several protected resources.
  defp well_known(url, suffix) do
    uri = URI.parse(url)
    path = String.trim_trailing(uri.path || "", "/")

    %{uri | path: suffix <> path, query: nil, fragment: nil} |> URI.to_string()
  end

  defp get(url, trust, opts) do
    with {:ok, options} <- Egress.options(url, trust, Keyword.get(opts, :req_options, [])) do
      case Req.get(options) do
        {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
        {:ok, %Req.Response{status: status}} -> {:error, {:metadata_unavailable, url, status}}
        {:error, reason} -> {:error, {:metadata_unreachable, url, reason}}
      end
    end
  end
end
