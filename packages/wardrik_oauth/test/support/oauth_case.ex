defmodule WardrikOAuth.Case do
  @moduledoc """
  An authorization server that answers without a socket, and a vault with a key.

  Requests are routed to a `Req.Test` stub through `config :wardrik, WardrikOAuth,
  req_options:`, so discovery, registration, exchange and refresh all run their
  real request building against a stub that reports what it was sent.

      use WardrikOAuth.Case

      test "..." do
        stub_server()
        ...
        assert_receive {:oauth, "POST", "/token", params}
      end
  """

  use ExUnit.CaseTemplate

  @stub WardrikOAuth.Stub

  defmodule Resolver do
    @moduledoc """
    Names resolved without DNS: a host under `internal.` or `metadata.` to a
    private address, `mixed.` to a public and a private one, and every other
    to a public one.
    """

    @spec resolve(String.t()) :: {:ok, [:inet.ip_address()]}
    def resolve("internal." <> _rest), do: {:ok, [{10, 0, 0, 5}]}
    def resolve("metadata." <> _rest), do: {:ok, [{169, 254, 169, 254}]}
    def resolve("mixed." <> _rest), do: {:ok, [{93, 184, 215, 14}, {192, 168, 1, 1}]}
    def resolve(_host), do: {:ok, [{93, 184, 215, 14}]}
  end

  using do
    quote do
      import WardrikOAuth.Case

      alias WardrikOAuth.Client
      alias WardrikOAuth.Flow
      alias WardrikOAuth.Metadata
      alias WardrikOAuth.Provider
      alias WardrikOAuth.Token
    end
  end

  setup do
    previous = %{
      oauth: Application.get_env(:wardrik, WardrikOAuth),
      vault: Application.get_env(:wardrik, WardrikVault)
    }

    Application.put_env(:wardrik, WardrikVault,
      keys: [WardrikVault.generate_key()],
      grants: WardrikOAuth
    )

    forget_registrations()

    on_exit(fn ->
      put_back(WardrikOAuth, previous.oauth)
      put_back(WardrikVault, previous.vault)
      forget_registrations()
    end)

    %{owner: "jon-#{System.unique_integer([:positive])}"}
  end

  # Clients registered dynamically are kept in the store, which outlives a test.
  defp forget_registrations do
    for key <- Wardrik.Store.keys(:oauth_clients, ""),
        do: Wardrik.Store.delete(:oauth_clients, key)
  end

  @doc "Configures `WardrikOAuth` with these options, plus the stub transport."
  @spec configure(keyword()) :: :ok
  def configure(opts) do
    defaults = [
      req_options: [plug: {Req.Test, @stub}],
      redirect: [uri: redirect_uri()],
      client: [name: "Wardrik", document_url: "https://wardrik.dev/oauth/client"],
      resolver: Resolver,
      poll_floor: 0
    ]

    Application.put_env(:wardrik, WardrikOAuth, Keyword.merge(defaults, opts))
  end

  @doc "The redirect URI the tests register."
  @spec redirect_uri() :: String.t()
  def redirect_uri, do: "http://127.0.0.1:4599/callback"

  @doc "Where the stub authorization server lives."
  @spec resource() :: String.t()
  def resource, do: "https://mcp.example.com/mcp"

  @doc """
  Answers as an authorization server would.

  Options:

    * `:cimd` - advertise Client ID Metadata Document support
    * `:register` - advertise a registration endpoint
    * `:oidc_only` - publish OpenID configuration and no OAuth metadata
    * `:device` - advertise a device authorization endpoint, answering with
      `device/1` merged with this map where it is one, and without the keys
      it sets to `nil`
    * `:token` - the body the token endpoint answers with
    * `:tokens` - what the token endpoint answers each request with, in turn,
      as `{status, body}`, and `:token` once they run out
    * `:as` - the authorization server the resource names, and whose
      endpoints the metadata lists, `https://auth.example.com` by default
    * `:resource_named` - the resource the resource metadata names
    * `:issuer_named` - the issuer the metadata names, `nil` for none
    * `:endpoints` - merged over the metadata's endpoints
    * `:no_pkce` - leave `code_challenge_methods_supported` out
    * `:redirect_prm` - answer the resource metadata with a redirect
    * `:iss` - say a callback carries `iss` (RFC 9207)
    * `:resource_scopes` - the scopes the resource metadata names
  """
  @spec stub_server(keyword()) :: :ok
  def stub_server(opts \\ []) do
    test = self()
    {:ok, tokens} = Agent.start_link(fn -> Keyword.get(opts, :tokens, []) end)
    opts = Keyword.put(opts, :tokens, tokens)

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(test, {:oauth, conn.method, conn.request_path, body})

      answer(conn, opts)
    end)
  end

  defp answer(conn, opts) do
    case {conn.method, conn.request_path} do
      {"GET", "/.well-known/oauth-protected-resource/mcp"} ->
        resource_metadata(conn, opts)

      {"GET", "/.well-known/oauth-authorization-server"} ->
        if opts[:oidc_only],
          do: Plug.Conn.resp(conn, 404, "no"),
          else: Req.Test.json(conn, metadata(opts))

      {"GET", "/.well-known/openid-configuration"} ->
        Req.Test.json(conn, metadata(opts))

      {"POST", "/register"} ->
        Req.Test.json(conn, %{
          "client_id" => "registered-id",
          "client_secret" => "registered-secret"
        })

      {"POST", "/device"} ->
        Req.Test.json(conn, device(device_overrides(opts[:device])))

      {"POST", "/token"} ->
        token_answer(conn, opts)

      {_method, _path} ->
        Plug.Conn.resp(conn, 404, "no")
    end
  end

  defp resource_metadata(conn, opts) do
    if opts[:redirect_prm] do
      conn
      |> Plug.Conn.put_resp_header("location", "https://elsewhere.example.com/prm")
      |> Plug.Conn.resp(302, "")
    else
      %{
        "resource" => Keyword.get(opts, :resource_named, resource()),
        "authorization_servers" => [authorization_server(opts)]
      }
      |> then(&if s = opts[:resource_scopes], do: Map.put(&1, "scopes_supported", s), else: &1)
      |> then(&Req.Test.json(conn, &1))
    end
  end

  defp device_overrides(overrides) when is_map(overrides), do: overrides
  defp device_overrides(_advertised), do: %{}

  # The next of the answers a test lined up, and the token once they run out.
  defp token_answer(conn, opts) do
    case Agent.get_and_update(opts[:tokens], &Enum.split(&1, 1)) do
      [{status, body}] -> conn |> Plug.Conn.put_status(status) |> Req.Test.json(body)
      [] -> Req.Test.json(conn, opts[:token] || token())
    end
  end

  defp authorization_server(opts), do: Keyword.get(opts, :as, "https://auth.example.com")

  defp metadata(opts) do
    base = authorization_server(opts)

    %{
      "issuer" => Keyword.get(opts, :issuer_named, base),
      "authorization_endpoint" => base <> "/authorize",
      "token_endpoint" => base <> "/token",
      "scopes_supported" => ["repo", "read:org"],
      "code_challenge_methods_supported" => if(opts[:no_pkce], do: nil, else: ["S256"])
    }
    |> Map.put("authorization_response_iss_parameter_supported", opts[:iss] == true)
    |> Map.merge(Keyword.get(opts, :endpoints, %{}))
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> then(
      &if opts[:cimd], do: Map.put(&1, "client_id_metadata_document_supported", true), else: &1
    )
    |> then(
      &if opts[:register], do: Map.put(&1, "registration_endpoint", base <> "/register"), else: &1
    )
    |> then(
      &if opts[:device],
        do: Map.put(&1, "device_authorization_endpoint", base <> "/device"),
        else: &1
    )
  end

  @doc "A device authorization endpoint's answer, with `overrides` merged in."
  @spec device(map()) :: map()
  def device(overrides \\ %{}) do
    %{
      "device_code" => "dc_first",
      "user_code" => "WDJB-MJHT",
      "verification_uri" => "https://auth.example.com/activate",
      "expires_in" => 900,
      "interval" => 0
    }
    |> Map.merge(overrides)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc "A token endpoint's answer, with `overrides` merged in."
  @spec token(map()) :: map()
  def token(overrides \\ %{}) do
    Map.merge(
      %{
        "access_token" => "at_first",
        "refresh_token" => "rt_first",
        "token_type" => "Bearer",
        "expires_in" => 3600,
        "scope" => "repo"
      },
      overrides
    )
  end

  @doc "The `state` parameter out of an authorization URL."
  @spec state_of(String.t()) :: String.t()
  def state_of(url),
    do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

  @doc "Every query parameter of a URL."
  @spec params_of(String.t()) :: map()
  def params_of(url), do: url |> URI.parse() |> Map.get(:query, "") |> URI.decode_query()

  @doc "Forgets what the stub has already reported, so the next assertion is about now."
  @spec flush() :: :ok
  def flush do
    receive do
      {:oauth, _method, _path, _body} -> flush()
    after
      0 -> :ok
    end
  end

  defp read_body(conn) do
    case conn.method do
      "GET" -> {:ok, "", conn}
      _other -> Plug.Conn.read_body(conn)
    end
  end

  defp put_back(key, nil), do: Application.delete_env(:wardrik, key)
  defp put_back(key, value), do: Application.put_env(:wardrik, key, value)
end
