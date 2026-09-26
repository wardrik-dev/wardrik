defmodule TarsOAuth.DeviceTest do
  use TarsOAuth.Case, async: false

  import ExUnit.CaptureLog

  alias Tars.Credential
  alias Tars.LLM.Config
  alias Tars.Scope
  alias Tars.Test.Calls
  alias TarsOAuth.Device
  alias TarsOAuth.Pending

  @grant "urn:ietf:params:oauth:grant-type:device_code"
  @stubbed [plug: {Req.Test, TarsOAuth.Stub}]
  # A device answer that has the poller wait a minute before it asks, for a
  # test that ends before then.
  @unhurried %{"interval" => 60}

  setup do
    start_supervised!({TarsOAuth.Supervisor, loopback: false})

    test = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:tars_oauth, :device, :done],
        fn _event, _measurements, metadata, _config -> send(test, {:device_done, metadata}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp metadata(opts) do
    stub_server(opts)
    {:ok, metadata} = Metadata.discover(resource(), req_options: @stubbed)
    flush()
    metadata
  end

  defp registered,
    do: %{client_id: "tars-client", client_secret: nil, redirect_uri: nil, how: :static}

  defp scope(owner),
    do: Config.new() |> Scope.root("acme/#{owner}/a", user: owner, credentials: TarsOAuth)

  defp provider(opts), do: [github: [resource: resource(), scopes: ~w(repo)] ++ opts]

  describe "request/3" do
    test "asks the server for a code, naming the client, scope and resource" do
      metadata = metadata(device: true)

      assert {:ok, %Device{} = device} =
               Device.request(metadata, registered(), scopes: ["repo"], req_options: @stubbed)

      assert device.user_code == "WDJB-MJHT"
      assert device.device_code == "dc_first"
      assert device.verification_uri == "https://auth.example.com/activate"
      assert device.expires_in == 900

      assert_receive {:oauth, "POST", "/device", body}

      assert URI.decode_query(body) == %{
               "client_id" => "tars-client",
               "scope" => "repo",
               "resource" => resource()
             }
    end

    test "reads the page as Google names it, and asks every five seconds unless told" do
      google = %{
        "verification_uri" => nil,
        "verification_url" => "https://www.google.com/device",
        "interval" => nil
      }

      assert {:ok, %Device{verification_uri: "https://www.google.com/device", interval: 5}} =
               Device.request(metadata(device: google), registered(), req_options: @stubbed)
    end

    test "refuses an answer missing what a user needs" do
      assert {:error, {:device_unreadable, _body}} =
               Device.request(metadata(device: %{"user_code" => nil}), registered(),
                 req_options: @stubbed
               )
    end

    test "says a server that offers no device grant does not" do
      assert Device.request(metadata([]), registered()) ==
               {:error, {:no_device_flow, "https://auth.example.com"}}
    end
  end

  describe "poll/4" do
    setup do
      device = %Device{
        device_code: "dc",
        user_code: "C",
        verification_uri: "https://auth.example.com/activate",
        expires_in: 60,
        interval: 0
      }

      %{metadata: metadata(device: true), device: device}
    end

    defp poll(context, answers) do
      stub_server(device: true, tokens: answers)
      Device.poll(context.metadata, registered(), context.device, req_options: @stubbed)
    end

    test "asks with the device code and grant, and reads a token", context do
      assert {:ok, %Token{access_token: "at_first"}} = poll(context, [{200, token()}])

      assert_receive {:oauth, "POST", "/token", body}

      assert %{"grant_type" => @grant, "device_code" => "dc", "client_id" => "tars-client"} =
               URI.decode_query(body)
    end

    test "reads a user who has not finished, however the server says so", context do
      assert poll(context, [{400, %{"error" => "authorization_pending"}}]) == :pending
      assert poll(context, [{200, %{"error" => "authorization_pending"}}]) == :pending
      assert poll(context, [{400, %{"error" => "slow_down"}}]) == :slow_down
    end

    test "reads the end of a flow as one", context do
      assert poll(context, [{400, %{"error" => "access_denied"}}]) == {:error, :access_denied}
      assert poll(context, [{400, %{"error" => "expired_token"}}]) == {:error, :expired}

      assert {:error, {:token_refused, 400, %{"error" => "invalid_client"}}} =
               poll(context, [{400, %{"error" => "invalid_client"}}])
    end

    test "waits five seconds longer once the server asks it to slow down" do
      assert Device.next_interval(:slow_down, 5_000) == 10_000
      assert Device.next_interval(:pending, 5_000) == 5_000
    end
  end

  describe "authorizing on another device" do
    test "gives a parked call the code and the page, and connects once the user has entered it",
         %{owner: owner} do
      stub_server(
        cimd: true,
        device: true,
        tokens: [{400, %{"error" => "authorization_pending"}}, {200, token()}]
      )

      configure(providers: provider(flow: :device))

      assert {:error, {:authorization_required, "https://auth.example.com/activate", "WDJB-MJHT"}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 {:user, "github"}
               )

      assert_receive {:device_done, %{provider: "github", owner: ^owner, outcome: :authorized}}
      assert_received {:oauth, "POST", "/token", _pending}
      assert_received {:oauth, "POST", "/token", _authorized}

      assert {:ok, credential} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 {:user, "github"}
               )

      assert Credential.reveal(credential) == "at_first"
    end

    test "offers the same code while the flow is under way", %{owner: owner} do
      stub_server(cimd: true, device: @unhurried)
      configure(providers: provider(flow: :device))

      first =
        Credential.resolve(Calls.tool("tool", %{}, scope(owner)), {:user, "github"})

      assert {:error, {:authorization_required, _url, "WDJB-MJHT"}} = first

      assert Credential.resolve(
               Calls.tool("tool", %{}, scope(owner)),
               {:user, "github"}
             ) == first
    end

    test "forgets a flow the user refused", %{owner: owner} do
      stub_server(cimd: true, device: true, tokens: [{400, %{"error" => "access_denied"}}])
      configure(providers: provider(flow: :device))

      log =
        capture_log(fn ->
          {:error, {:authorization_required, _url, _code}} =
            Credential.resolve(Calls.tool("tool", %{}, scope(owner)), {:user, "github"})

          assert_receive {:device_done, %{outcome: :access_denied}}
        end)

      assert log =~ "github was not connected for #{inspect(owner)}: :access_denied"
      assert Pending.under_way("github", owner) == :error
      refute TarsOAuth.connected?("github", owner)
    end

    test "says a server that offers no device grant cannot be asked for one", %{owner: owner} do
      stub_server(cimd: true)
      configure(providers: provider(flow: :device))

      assert Credential.resolve(
               Calls.tool("tool", %{}, scope(owner)),
               {:user, "github"}
             ) ==
               {:error, {:no_device_flow, "https://auth.example.com"}}
    end

    test "registers a client that may use the device grant where the server offers it", %{
      owner: owner
    } do
      stub_server(register: true, device: @unhurried)
      configure(providers: provider(flow: :device), client: [name: "Tars"])

      {:error, {:authorization_required, _url, _code}} =
        Credential.resolve(Calls.tool("tool", %{}, scope(owner)), {:user, "github"})

      assert_received {:oauth, "POST", "/register", body}
      assert @grant in JSON.decode!(body)["grant_types"]
    end
  end

  describe "choosing how, by default" do
    defp resolve(owner, redirect) do
      stub_server(cimd: true, device: @unhurried)
      configure(providers: provider([]), redirect: redirect)
      Credential.resolve(Calls.tool("tool", %{}, scope(owner)), {:user, "github"})
    end

    test "is on another device where the redirect comes back here and there is no browser", %{
      owner: owner
    } do
      assert {:error, {:authorization_required, _url, "WDJB-MJHT"}} =
               resolve(owner, open: false, opener: "no-such-opener-anywhere")
    end

    test "is in a browser where the redirect comes back somewhere else", %{owner: owner} do
      assert {:error, {:authorization_required, url}} = resolve(owner, uri: redirect_uri())
      assert String.starts_with?(url, "https://auth.example.com/authorize?")
    end

    test "is in a browser where the provider says so", %{owner: owner} do
      stub_server(cimd: true, device: true)

      configure(
        providers: provider(flow: :browser),
        redirect: [open: false, opener: "no-such-opener-anywhere"]
      )

      assert {:error, {:authorization_required, url}} =
               Credential.resolve(
                 Calls.tool("tool", %{}, scope(owner)),
                 {:user, "github"}
               )

      assert String.starts_with?(url, "https://auth.example.com/authorize?")
    end
  end
end
