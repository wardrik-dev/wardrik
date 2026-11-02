defmodule WardrikDaemon.PairingTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureIO
  import WardrikDaemon.Test

  alias WardrikCore.Principal
  alias WardrikDaemon.CLI
  alias WardrikDaemon.Client
  alias WardrikDaemon.Pairings
  alias WardrikDaemon.Tokens
  alias WardrikOAuth.Device
  alias WardrikOAuth.Token

  setup :set_mimic_global

  setup context do
    context = dirs(context)
    port = free_port()

    write(context, "config.yaml", """
    org: payments
    allow_private_urls: true
    http: {port: #{port}}
    defaults: {model: #{model()}}
    oauth:
      providers:
        crm:
          authorization_endpoint: https://crm.test/authorize
          token_endpoint: https://crm.test/token
          client_id: deployment-crm
        notes:
          authorization_endpoint: https://notes.test/authorize
          token_endpoint: https://notes.test/token
          client_id: deployment-notes
          flow: device
    """)

    test = self()

    stub(WardrikOAuth.Browser, :exchange, fn _metadata, _provider, args ->
      send(test, {:exchanged, Keyword.fetch!(args, :code)})
      {:ok, %Token{access_token: "at", token_endpoint: "https://crm.test/token"}}
    end)

    context = start_daemon(context)
    running = Wardrik.Instance.fetch!(context.wardrik)
    Map.merge(context, %{url: "http://127.0.0.1:#{port}", running: running})
  end

  defp client(context, subject) do
    {:ok, %{secret: secret}} =
      Tokens.create(context.daemon_store,
        name: "test",
        subject: subject,
        expires: DateTime.add(DateTime.utc_now(), 1, :hour)
      )

    %Client{url: context.url, secret: secret}
  end

  # Starts the client's browser sign-in, and returns the state the provider sends back.
  defp started(client, provider) do
    assert {:ok, %{"authorization" => %{"url" => url} = authorization}} =
             Client.run(client, "connections.connect", %{"provider" => provider})

    refute Map.has_key?(authorization, "code")
    URI.decode_query(URI.parse(url).query)["state"]
  end

  defp callback(context, params) do
    Req.get!(context.url <> "/oauth/callback", params: params, retry: false)
  end

  defp code(response) do
    case Regex.run(~r/class="code">([^<]+)</, response.body) do
      [_match, code] -> code
      nil -> nil
    end
  end

  defp pair(client, provider, code),
    do: Client.run(client, "connections.pair", %{"provider" => provider, "code" => code})

  defp connected?(context, id, provider) do
    vault = Wardrik.vault(context.running)
    match?({:ok, _grant}, WardrikVault.fetch(vault, %Principal{id: id}, provider))
  end

  test "a code finishes only the sign-in its own principal started", context do
    ana = client(context, "user:payments/@ana")
    bo = client(context, "user:payments/@bo")

    state = started(ana, "crm")
    _bo_state = started(bo, "crm")
    code = code(callback(context, %{"state" => state, "code" => "from-crm"}))

    assert {:error, "invalid_request", message} = pair(bo, "crm", code)
    refute message =~ "ana"
    refute connected?(context, "payments/@bo", "crm")
    refute connected?(context, "payments/@ana", "crm")

    # Cy started no sign-in at all, and learns no more.
    cy = client(context, "user:payments/@cy")
    assert {:error, "invalid_request", ^message} = pair(cy, "crm", code)

    # Ana's sign-in stays open for her, and her code reads in any case, with or without its dash.
    assert {:ok, %{"provider" => "crm", "connected" => true}} =
             pair(ana, "crm", code |> String.downcase() |> String.replace("-", ""))

    assert_received {:exchanged, "from-crm"}
    assert connected?(context, "payments/@ana", "crm")
    refute connected?(context, "payments/@bo", "crm")
  end

  test "a code is 8 letters of the alphabet, used once, and ends after 5 wrong tries", context do
    ana = client(context, "user:payments/@ana")
    state = started(ana, "crm")
    code = code(callback(context, %{"state" => state, "code" => "from-crm"}))

    assert code =~ ~r/\A[BCDFGHJKLMNPQRSTVWXZ]{4}-[BCDFGHJKLMNPQRSTVWXZ]{4}\z/
    wrong = if code == "BCDF-GHJK", do: "ZXWV-TSRQ", else: "BCDF-GHJK"

    for _try <- 1..4,
        do: assert({:error, "invalid_request", _message} = pair(ana, "crm", wrong))

    assert {:ok, %{"connected" => true}} = pair(ana, "crm", code)
    assert {:error, "invalid_request", reused} = pair(ana, "crm", code)
    assert reused =~ "doesn't match"

    # Five wrong codes abandon it: the right one fails after, and the provider's link is dead.
    bo = client(context, "user:payments/@bo")
    state = started(bo, "crm")
    params = %{"state" => state, "code" => "from-crm"}
    code = code(callback(context, params))

    for _try <- 1..4,
        do: assert({:error, "invalid_request", _message} = pair(bo, "crm", wrong))

    assert {:error, "invalid_request", ended} = pair(bo, "crm", wrong)
    assert ended =~ "This sign-in has ended."
    assert {:error, "invalid_request", _message} = pair(bo, "crm", code)
    assert code(callback(context, params)) == nil

    oauth = Wardrik.oauth(context.running)
    as = [as: %Principal{id: "payments/@bo"}]
    assert {:error, :no_such_flow} = WardrikOAuth.finish(oauth, params, as)
    refute connected?(context, "payments/@bo", "crm")
  end

  test "a code expires after 10 minutes", context do
    ana = client(context, "user:payments/@ana")
    state = started(ana, "crm")
    code = code(callback(context, %{"state" => state, "code" => "from-crm"}))

    pairings = Pairings.name(context.wardrik)
    past = System.monotonic_time(:millisecond) - 1

    :sys.replace_state(pairings, fn sign_ins ->
      Map.new(sign_ins, fn {state, held} -> {state, %{held | until: past}} end)
    end)

    assert {:error, "invalid_request", message} = pair(ana, "crm", code)
    assert message =~ "This sign-in has ended."
    assert {:error, "invalid_request", _message} = pair(ana, "crm", code)
    refute connected?(context, "payments/@ana", "crm")
  end

  test "the callback alone never connects an account", context do
    ana = client(context, "user:payments/@ana")
    state = started(ana, "crm")

    response = callback(context, %{"state" => state, "code" => "from-crm"})
    assert response.status == 200
    assert response.body =~ "wardrik connection connect"
    assert ["no-store"] = Req.Response.get_header(response, "cache-control")

    refute_received {:exchanged, _code}
    refute connected?(context, "payments/@ana", "crm")

    assert {:ok, %{"connections" => connections}} = Client.run(ana, "connections.list", %{})
    assert %{"provider" => "crm", "connected" => false, "signing_in" => true} in connections

    # A callback no sign-in here started, or one declined, shows no code.
    assert callback(context, %{"state" => "made-up", "code" => "x"}).status == 404
    assert code(callback(context, %{"state" => "made-up", "code" => "x"})) == nil

    declined = callback(context, %{"state" => state, "error" => "access_denied"})
    assert declined.status == 400
    assert code(declined) == nil
    refute connected?(context, "payments/@ana", "crm")

    assert {:ok, %{"connections" => connections}} = Client.run(ana, "connections.list", %{})
    assert %{"provider" => "crm", "connected" => false, "signing_in" => false} in connections
  end

  test "the wardrik command stops waiting once a device sign-in is declined", context do
    stub(Device, :request, fn _metadata, _provider, _req ->
      {:ok,
       %Device{
         device_code: "dc",
         user_code: "WDJB-MJHT",
         verification_uri: "https://notes.test/device",
         expires_in: 900,
         interval: 0
       }}
    end)

    stub(Device, :poll, fn _metadata, _provider, _args -> {:error, :access_denied} end)

    error =
      capture_io(:stderr, fn ->
        {status, output} = cli(context, ["connection", "connect", "notes"])
        assert status != 0
        assert output =~ "with the code WDJB-MJHT"
      end)

    assert error =~ "The sign-in to notes ended without connecting it."
    refute connected?(context, "admin", "notes")
  end

  test "a device sign-in shows the provider's code, never a pairing code", context do
    test = self()

    stub(Device, :request, fn _metadata, _provider, _req ->
      {:ok,
       %Device{
         device_code: "dc",
         user_code: "WDJB-MJHT",
         verification_uri: "https://notes.test/device",
         expires_in: 900,
         interval: 0
       }}
    end)

    stub(Device, :poll, fn _metadata, _provider, _args ->
      send(test, :polled)
      {:ok, %Token{access_token: "at", token_endpoint: "https://notes.test/token"}}
    end)

    {status, output} = cli(context, ["connection", "connect", "notes"])
    assert status == 0
    assert output =~ "Sign in to notes at https://notes.test/device with the code WDJB-MJHT"
    assert output =~ "Connected notes."
    refute output =~ "Code from the page"
    assert_received :polled
    assert connected?(context, "admin", "notes")

    assert callback(context, %{"state" => "dc", "code" => "x"}).status == 404

    assert {:error, "invalid_request", _message} =
             pair(client(context, "user:admin"), "notes", "BCDF-GHJK")
  end

  test "the wardrik command asks for the code the page shows", context do
    admin = client(context, "user:admin")
    state = started(admin, "crm")
    code = code(callback(context, %{"state" => state, "code" => "from-crm"}))
    env = Map.put(context.env, "WARDRIK_INPUT", "1")

    {status, output} =
      cli(%{context | env: env}, ["connection", "connect", "crm"], "nope\n#{code}\n")

    assert status == 0
    assert output =~ "Sign in to crm at https://crm.test/authorize?"
    assert output =~ "doesn't match"
    assert output =~ "Connected crm."
    assert connected?(context, "admin", "crm")

    {status, output} = cli(context, ["connection", "connect", "crm"])
    assert status == 0
    assert output =~ "crm is connected already."
  end

  defp cli(context, argv, input \\ "") do
    output =
      capture_io(input, fn -> send(self(), {:status, CLI.main(argv, env: context.env)}) end)

    assert_received {:status, status}
    {status, output}
  end
end
