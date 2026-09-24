defmodule TarsOAuth.Metadata do
  @moduledoc """
  What a server says about how to authorize against it, found rather than
  configured.

  `discover/2` walks the chain the MCP authorization spec describes:

      the resource                      https://mcp.example.com/mcp
        -> protected resource metadata  /.well-known/oauth-protected-resource  (RFC 9728)
        -> the authorization server     /.well-known/oauth-authorization-server (RFC 8414)
        -> or, failing that             /.well-known/openid-configuration

  A deployment that knows the issuer already can skip the first leg with
  `:issuer`, and one talking to a server that publishes nothing can state the
  endpoints itself.

  `:client_id_metadata_document_supported` is what decides whether this
  deployment can present a URL as its `client_id` instead of registering, and
  `:device_authorization_endpoint` whether a user can authorize from another
  device; see `TarsOAuth.Device`.
  """

  @enforce_keys [:issuer, :authorization_endpoint, :token_endpoint]
  defstruct [
    :issuer,
    :authorization_endpoint,
    :token_endpoint,
    :registration_endpoint,
    :device_authorization_endpoint,
    :resource,
    scopes_supported: [],
    code_challenge_methods_supported: [],
    cimd_supported?: false
  ]

  @typedoc "An authorization server, as it describes itself."
  @type t() :: %__MODULE__{
          issuer: String.t(),
          authorization_endpoint: String.t(),
          token_endpoint: String.t(),
          registration_endpoint: String.t() | nil,
          device_authorization_endpoint: String.t() | nil,
          resource: String.t() | nil,
          scopes_supported: [String.t()],
          code_challenge_methods_supported: [String.t()],
          cimd_supported?: boolean()
        }

  @resource_metadata "/.well-known/oauth-protected-resource"
  @as_metadata "/.well-known/oauth-authorization-server"
  @oidc_metadata "/.well-known/openid-configuration"

  @doc """
  Finds the authorization server behind `resource`.

  Options:

    * `:issuer` - skip the resource leg and ask this issuer directly
    * `:req_options` - merged into every request
  """
  @spec discover(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def discover(resource, opts \\ []) when is_binary(resource) do
    with {:ok, issuer} <- issuer(resource, opts) do
      issuer |> authorization_server(opts) |> put_resource(resource)
    end
  end

  @doc """
  The issuer a `WWW-Authenticate` header points at.

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
      issuer -> {:ok, issuer}
    end
  end

  defp from_resource(resource, opts) do
    case get(well_known(resource, @resource_metadata), opts) do
      {:ok, %{"authorization_servers" => [issuer | _rest]}} -> {:ok, issuer}
      {:ok, %{"issuer" => issuer}} -> {:ok, issuer}
      {:ok, _body} -> {:error, {:no_authorization_server, resource}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorization_server(issuer, opts) do
    case get(well_known(issuer, @as_metadata), opts) do
      {:ok, body} -> read(body, issuer)
      {:error, _reason} -> openid_configuration(issuer, opts)
    end
  end

  defp openid_configuration(issuer, opts) do
    with {:ok, body} <- get(well_known(issuer, @oidc_metadata), opts), do: read(body, issuer)
  end

  defp read(%{"authorization_endpoint" => authorize, "token_endpoint" => token} = body, issuer) do
    {:ok,
     %__MODULE__{
       issuer: body["issuer"] || issuer,
       authorization_endpoint: authorize,
       token_endpoint: token,
       registration_endpoint: body["registration_endpoint"],
       device_authorization_endpoint: body["device_authorization_endpoint"],
       scopes_supported: body["scopes_supported"] || [],
       code_challenge_methods_supported: body["code_challenge_methods_supported"] || [],
       cimd_supported?: body["client_id_metadata_document_supported"] == true
     }}
  end

  defp read(body, issuer), do: {:error, {:metadata_incomplete, issuer, Map.keys(body)}}

  defp put_resource({:ok, %__MODULE__{} = metadata}, resource),
    do: {:ok, %{metadata | resource: resource}}

  defp put_resource(error, _resource), do: error

  # RFC 9728 puts the resource's own path after the well-known segment, so one
  # host can serve several protected resources.
  defp well_known(url, suffix) do
    uri = URI.parse(url)
    path = String.trim_trailing(uri.path || "", "/")

    %{uri | path: suffix <> path, query: nil, fragment: nil} |> URI.to_string()
  end

  defp get(url, opts) do
    options = Keyword.merge([url: url, retry: false], Keyword.get(opts, :req_options, []))

    case Req.get(options) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) -> {:ok, body}
      {:ok, %Req.Response{status: status}} -> {:error, {:metadata_unavailable, url, status}}
      {:error, reason} -> {:error, {:metadata_unreachable, url, reason}}
    end
  end
end
