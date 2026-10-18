defmodule WardrikOAuth.RenewTest do
  use WardrikOAuth.Test.Case, async: false

  import ExUnit.CaptureLog

  alias Wardrik.AgentID
  alias Wardrik.Credential
  alias Wardrik.LLM.Config
  alias Wardrik.Run
  alias Wardrik.Test.Calls

  setup do
    start_supervised!({WardrikOAuth.Supervisor, oauth: oauth(), loopback: false})
    :ok = configure([])

    test = self()
    handler = "renew-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:wardrik_oauth, :device, :done],
      fn _event, _measurements, metadata, _config -> send(test, {:device_done, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp run(owner) do
    id = AgentID.new!("a", org: "acme", user: owner)
    Config.new() |> Run.root(id, host: host())
  end

  defp call(owner), do: Calls.tool("tool", %{}, run(owner))

  defp resolve(owner), do: Credential.resolve(call(owner), "github")

  defp provider(opts \\ []),
    do: [github: Keyword.merge([resource: resource(), scopes: ~w(repo)], opts)]

  # A token as a finished flow keeps it, expired unless `overrides` say not.
  defp keep(owner, overrides \\ %{}) do
    fields = %{
      access_token: "at_old",
      refresh_token: "rt_old",
      expires_at: System.system_time(:second) - 60,
      issuer: "https://auth.example.com",
      token_endpoint: "https://auth.example.com/token",
      client_id: "https://wardrik.dev/oauth/client",
      resource: resource()
    }

    token = struct(Token, Map.merge(fields, overrides))

    :ok =
      WardrikVault.put(vault(), "github", {"acme", owner},
        value: Token.encode(token),
        kind: :grant
      )
  end

  defp kept(owner) do
    {:ok, encoded} = WardrikVault.fetch(vault(), "github", {"acme", owner})
    {:ok, token} = Token.decode(encoded)
    token
  end

  defp renewed, do: token(%{"access_token" => "at_new", "refresh_token" => "rt_new"})

  defp token_posts, do: posts("/token", [])

  defp posts(path, found) do
    receive do
      {:oauth, "POST", ^path, body} -> posts(path, [URI.decode_query(body) | found])
    after
      0 -> Enum.reverse(found)
    end
  end

  describe "an expired token" do
    test "is renewed where it came from, as the client it was issued to, discovering nothing",
         %{owner: owner} do
      stub_server(cimd: true, token: renewed())
      configure(providers: provider())
      keep(owner)

      assert {:ok, credential} = resolve(owner)
      assert Credential.reveal(credential) == "at_new"

      assert [sent] = token_posts()
      assert sent["grant_type"] == "refresh_token"
      assert sent["refresh_token"] == "rt_old"
      assert sent["client_id"] == "https://wardrik.dev/oauth/client"
      assert sent["resource"] == resource()
      refute_received {:oauth, "GET", _path, _body}

      assert %Token{refresh_token: "rt_new", issuer: "https://auth.example.com"} = kept(owner)
    end

    test "whose refresh token the server no longer takes asks the user again", %{owner: owner} do
      stub_server(cimd: true, tokens: [{400, %{"error" => "invalid_grant"}}])
      configure(providers: provider())
      keep(owner)

      assert {:error, {:authorization_required, _link, _owner}} = resolve(owner)
    end

    test "at a server that cannot be reached fails the call, starts nothing, and keeps the token",
         %{owner: owner} do
      stub_server(cimd: true, tokens: [{503, %{}}])
      configure(providers: provider())
      keep(owner)

      assert {:error, {:token_refused, "http_503", nil}} = resolve(owner)
      assert %Token{access_token: "at_old", refresh_token: "rt_old"} = kept(owner)
      refute_received {:oauth, "GET", _path, _body}
    end

    test "is renewed with the provider's secret only when it came from the issuer named",
         %{owner: owner} do
      stub_server(cimd: true, token: renewed())

      configure(
        providers:
          provider(
            issuer: "https://auth.example.com",
            client_id: "Iv1.hand",
            client_secret: "s3cret"
          )
      )

      keep(owner, %{client_id: "Iv1.hand"})
      assert {:ok, _credential} = resolve(owner)
      assert [%{"client_secret" => "s3cret", "client_id" => "Iv1.hand"}] = token_posts()

      other = owner <> "-elsewhere"
      keep(other, %{client_id: "Iv1.hand", issuer: "https://other.example.com"})
      assert {:ok, _credential} = resolve(other)
      assert [sent] = token_posts()
      refute Map.has_key?(sent, "client_secret")
    end

    test "is renewed by one process at a time, and the rest use what it wrote", %{owner: owner} do
      stub_server(cimd: true, token: renewed())
      configure(providers: provider())
      keep(owner)
      call = call(owner)

      results =
        1..5
        |> Enum.map(fn _n -> Task.async(fn -> Credential.resolve(call, "github") end) end)
        |> Task.await_many()

      assert Enum.all?(results, &match?({:ok, _credential}, &1))
      assert [_one] = token_posts()
    end
  end

  test "a token a server refused is renewed on the next resolve", %{owner: owner} do
    stub_server(cimd: true, token: renewed())
    configure(providers: provider())
    keep(owner, %{expires_at: System.system_time(:second) + 3600})

    assert {:ok, credential} = resolve(owner)
    assert Credential.reveal(credential) == "at_old"
    assert token_posts() == []

    :ok = Credential.refused(call(owner), "github")

    assert {:ok, credential} = resolve(owner)
    assert Credential.reveal(credential) == "at_new"
    assert [%{"grant_type" => "refresh_token"}] = token_posts()
  end

  test "a token that cannot be read is asked for again, and left where it is", %{owner: owner} do
    stub_server(cimd: true)
    configure(providers: provider())

    :ok =
      WardrikVault.put(vault(), "github", {"acme", owner}, value: "not a token", kind: :grant)

    log =
      capture_log(fn ->
        assert {:error, {:authorization_required, _link, _owner}} = resolve(owner)
      end)

    assert log =~ "cannot be read (token_unreadable); asking again"

    assert {:ok, "not a token"} =
             WardrikVault.fetch(vault(), "github", {"acme", owner})
  end

  test "a vault with no key is an error, and starts nothing", %{owner: owner} do
    stub_server(cimd: true)
    configure(providers: provider())
    rekey([])

    assert {:error, :no_key} = resolve(owner)
    refute_received {:oauth, _method, _path, _body}
  end

  test "a browser flow wants a server that takes a SHA-256 challenge", %{owner: owner} do
    stub_server(cimd: true, no_pkce: true)
    configure(providers: provider(flow: :browser))

    assert {:error, {:no_pkce, "https://auth.example.com"}} = resolve(owner)
  end

  describe "a client registered dynamically" do
    test "is registered once, whoever asks", %{owner: owner} do
      stub_server(register: true)
      configure(providers: provider())

      assert {:error, {:authorization_required, _link, _owner}} = resolve(owner)
      assert {:error, {:authorization_required, _link, _owner}} = resolve(owner <> "-second")

      assert [_registered] = posts("/register", [])
    end

    test "that a server no longer knows is registered again", %{owner: owner} do
      stub_server(register: true, tokens: [{401, %{"error" => "invalid_client"}}])
      configure(providers: provider())

      assert {:error, {:authorization_required, _link, _owner}} = resolve(owner)
      assert [_registered] = posts("/register", [])

      second = owner <> "-second"
      keep(second, %{client_id: "registered-id"})

      assert {:error, {:authorization_required, _link, _owner}} = resolve(second)
      assert [%{"client_id" => "registered-id"}] = token_posts()
      assert [_registered_again] = posts("/register", [])
    end
  end

  test "a device flow asks again past a server that fails, and connects", %{owner: owner} do
    stub_server(
      cimd: true,
      device: true,
      tokens: [{503, %{}}, {400, %{"error" => "authorization_pending"}}, {200, token()}]
    )

    configure(providers: provider(flow: :device))

    assert {:error, {:authorization_required, %{code: "WDJB-MJHT"}, _owner}} = resolve(owner)
    assert_receive {:device_done, %{owner: {"acme", ^owner}, outcome: :authorized}}

    assert %Token{access_token: "at_first", token_endpoint: "https://auth.example.com/token"} =
             kept(owner)
  end
end
