defmodule TarsOAuth.Case do
  @moduledoc """
  An authorization server that answers without a socket, and a vault with a key.

  Requests are routed to a `Req.Test` stub through `config :tars, TarsOAuth,
  req_options:`, so discovery, registration, exchange and refresh all run their
  real request building against a stub that reports what it was sent.

      use TarsOAuth.Case

      test "..." do
        stub_server()
        ...
        assert_receive {:oauth, "POST", "/token", params}
      end
  """

  use ExUnit.CaseTemplate

  @stub TarsOAuth.Stub

  using do
    quote do
      import TarsOAuth.Case

      alias TarsOAuth.Client
      alias TarsOAuth.Flow
      alias TarsOAuth.Metadata
      alias TarsOAuth.Provider
      alias TarsOAuth.Token
    end
  end

  setup do
    previous = %{
      oauth: Application.get_env(:tars, TarsOAuth),
      vault: Application.get_env(:tars, TarsVault)
    }

    Application.put_env(:tars, TarsVault, keys: [TarsVault.generate_key()])

    on_exit(fn ->
      put_back(TarsOAuth, previous.oauth)
      put_back(TarsVault, previous.vault)
    end)

    %{owner: "jon-#{System.unique_integer([:positive])}"}
  end

  @doc "Configures `TarsOAuth` with these options, plus the stub transport."
  @spec configure(keyword()) :: :ok
  def configure(opts) do
    defaults = [
      req_options: [plug: {Req.Test, @stub}],
      redirect: [uri: redirect_uri()],
      client: [name: "Tars", document_url: "https://tars.dev/oauth/client"]
    ]

    Application.put_env(:tars, TarsOAuth, Keyword.merge(defaults, opts))
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
    * `:token` - the body the token endpoint answers with
  """
  @spec stub_server(keyword()) :: :ok
  def stub_server(opts \\ []) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      {:ok, body, conn} = read_body(conn)
      send(test, {:oauth, conn.method, conn.request_path, body})

      answer(conn, opts)
    end)
  end

  defp answer(conn, opts) do
    case {conn.method, conn.request_path} do
      {"GET", "/.well-known/oauth-protected-resource/mcp"} ->
        Req.Test.json(conn, %{"authorization_servers" => ["https://auth.example.com"]})

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

      {"POST", "/token"} ->
        Req.Test.json(conn, opts[:token] || token())

      {_method, _path} ->
        Plug.Conn.resp(conn, 404, "no")
    end
  end

  defp metadata(opts) do
    %{
      "issuer" => "https://auth.example.com",
      "authorization_endpoint" => "https://auth.example.com/authorize",
      "token_endpoint" => "https://auth.example.com/token",
      "scopes_supported" => ["repo", "read:org"],
      "code_challenge_methods_supported" => ["S256"]
    }
    |> then(
      &if opts[:cimd], do: Map.put(&1, "client_id_metadata_document_supported", true), else: &1
    )
    |> then(
      &if opts[:register],
        do: Map.put(&1, "registration_endpoint", "https://auth.example.com/register"),
        else: &1
    )
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

  defp put_back(key, nil), do: Application.delete_env(:tars, key)
  defp put_back(key, value), do: Application.put_env(:tars, key, value)
end
