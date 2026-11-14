defmodule Wardrik.Store.FormatsTest do
  use ExUnit.Case, async: true

  alias Wardrik.MCP.Server
  alias Wardrik.OAuth.Apps
  alias Wardrik.Operations.NotifyTargets
  alias Wardrik.Operations.Servers
  alias Wardrik.Store.Format
  alias Wardrik.Vault.Sealed
  alias Wardrik.Workspace.File

  defp round_trip(format, value), do: Format.decode(format, Format.encode(format, value))

  test "keeps an OAuth app's options as the fields it was added with" do
    app = %{
      owner: "acme",
      name: "linear",
      id: "abc",
      secret: "LINEAR_SECRET",
      opts: [
        issuer: "https://linear.app",
        client_id: "client",
        scopes: ["read"],
        client_auth: :basic,
        flow: :device,
        authorization_params: %{"prompt" => "consent"}
      ]
    }

    assert %{"fields" => %{"client_auth" => "basic", "flow" => "device"}} = Apps.dump(app)
    assert {:ok, loaded} = round_trip(Apps, app)
    assert %{loaded | opts: Enum.sort(loaded.opts)} == %{app | opts: Enum.sort(app.opts)}
  end

  test "keeps a server's record and a notify target as they were" do
    server = %{
      owner: "acme",
      name: "crm",
      url: "https://crm.example/mcp",
      auth: "oauth",
      provider: nil,
      credential: "acme:server:crm"
    }

    target = %{owner: "acme", name: "ops", url: "https://hooks.example/ops", secret: nil}

    assert round_trip(Servers, server) == {:ok, server}
    assert round_trip(NotifyTargets, target) == {:ok, target}
  end

  test "keeps a sealed value's kind and bytes, and refuses a kind it doesn't know" do
    sealed =
      Sealed.seal("ghp_secret", key: :crypto.strong_rand_bytes(32), path: "p", kind: :header)

    assert round_trip(Sealed, sealed) == {:ok, sealed}

    assert {:error, _reason} =
             Sealed.load(1, %{Sealed.dump(sealed) | "kind" => "unheard_of"})
  end

  test "keeps a file's time to the microsecond" do
    file = %File{content: "Hi", by: "agt_1", at: DateTime.utc_now(), labels: ["outside"]}
    assert round_trip(File, file) == {:ok, file}
    assert round_trip(File, %File{content: "Hi"}) == {:ok, %File{content: "Hi"}}
  end

  test "keeps a server's options, with its transport and header secrets" do
    http = [
      transport:
        {:streamable_http,
         url: "https://crm.example/mcp",
         headers: %{
           "authorization" => ["Bearer ", {:secret, "CRM_KEY"}],
           "x-key" => {:secret, "K"}
         }},
      prefix: "crm",
      owner: "acme",
      only: ["search"],
      gated: true,
      cost: [usd: 0.001]
    ]

    stdio = [transport: {:stdio, command: "notes", args: ["--stdio"], env: %{"A" => "1"}}]

    assert %{"transport" => %{"type" => "streamable_http"}} = Server.dump(http)

    for opts <- [http, stdio] do
      assert {:ok, loaded} = round_trip(Server, opts)
      assert normalized(loaded) == normalized(opts)
    end

    assert {:error, _reason} = Server.load(1, %{"unheard_of" => true})
    assert {:error, _reason} = Server.load(1, %{"transport" => %{"type" => "carrier_pigeon"}})
  end

  defp normalized(opts) do
    opts
    |> Enum.map(fn
      {:transport, {type, transport}} -> {:transport, {type, Enum.sort(transport)}}
      option -> option
    end)
    |> Enum.sort()
  end
end
