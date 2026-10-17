defmodule WardrikDaemonTest do
  use ExUnit.Case, async: false

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix
  alias WardrikDaemon.Config
  alias WardrikDaemon.Test.Host
  alias WardrikDaemon.Test.Settings

  @moduletag :tmp_dir

  # What the daemon's tree reads, over what the suite's release gives.
  defp load(dir) do
    Config.load(
      store: store(),
      adapters: WardrikChannel.discover(),
      triggers: WardrikTrigger.Offered.discover(),
      base: Host.config(dir).sections,
      config_dir: dir,
      data_dir: dir,
      state_dir: dir
    )
  end

  # The daemon, started as its tree starts it on what `dir` holds, with its
  # config and host.
  defp daemon(dir) do
    {:ok, config} = load(dir)

    agents = %{
      Host.agents(dir)
      | config: config,
        context: WardrikDaemon.AgentFile.context(config)
    }

    host = Host.host(agents)
    {start_supervised({WardrikDaemon, host: host, config: config}), config, host}
  end

  test "starts with no config.yaml at all, running the agent files, the servers people add and the HTTP API",
       %{tmp_dir: dir} do
    assert {{:ok, pid}, _config, _host} = daemon(dir)

    assert [WardrikDaemon.Agents, WardrikHTTP.Listener, WardrikMCP.Supervisor] =
             pid |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  test "defines the agents sent to its HTTP API as it reads agent files", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "config.yaml"), "orgs:\n  daemon: {}\n")
    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join([dir, "policies", "careful.yaml"]), "deny: [run_lua]\n")

    {:ok, secret, _token} =
      WardrikHTTP.Token.create(Wardrik.Test.store(), "daemon-test",
        scope: Prefix.parse!("daemon/"),
        can: Wardrik.Grant.actions(),
        ceiling: []
      )

    key = AgentID.parse!("daemon/defined-#{System.unique_integer([:positive])}")
    on_exit(fn -> Wardrik.Fleet.forget(key) end)

    {{:ok, _pid}, _config, _host} = daemon(dir)

    {:ok, port} = WardrikHTTP.Listener.port()

    api =
      Req.new(
        base_url: "http://127.0.0.1:#{port}/v1/agents/#{key}",
        auth: {:bearer, secret},
        retry: false
      )

    assert {:ok, %{status: 400, body: body}} = Req.put(api, json: %{"policy" => "lax"})
    assert body["error"]["message"] == "policy names lax, which is not a policy in policies/"

    assert {:ok, %{status: 200}} =
             Req.put(api, json: %{"policy" => "careful", "instructions" => "You help."})

    assert Wardrik.Fleet.lookup(key)

    assert {:ok,
            %{
              status: 200,
              body: %{
                "definition" => %{"policy" => "careful", "instructions" => "You help."},
                "missing" => []
              }
            }} = Req.get(api, url: "definition")

    assert {:ok, %{status: 204}} = Req.delete(api)
    assert Wardrik.Fleet.lookup(key) == nil
    assert {:ok, %{status: 404}} = Req.get(api, url: "definition")
  end

  test "keeps config.yaml's settings, and starts the vault with its own", %{tmp_dir: dir} do
    key = WardrikVault.generate_key()
    File.write!(Path.join(dir, "config.yaml"), "vault:\n  keys: [\"#{key}\"]\n")

    assert {{:ok, _pid}, config, host} = daemon(dir)

    assert Config.section(config, WardrikVault)[:keys] == [key]
    assert Wardrik.Host.credentials(host).keys == [key]
    assert %WardrikOAuth{} = Wardrik.Host.credentials(host).grants
  end

  test "starts what config.yaml configures with its section as options", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "config.yaml"), """
    channels:
      chat:
        type: test
        token: xoxb-1
    notify:
      audit:
        webhook:
          url: https://hooks.example.com/wardrik
      ops:
        channel: chat
        room: "#ops"
    """)

    assert {{:ok, pid}, config, _host} = daemon(dir)

    children = Enum.map(Supervisor.which_children(pid), &elem(&1, 0))
    assert WardrikNotify.Supervisor in children
    assert WardrikChannel.Supervisor in children

    assert [audit: {WardrikNotify.Webhook, _opts}, ops: {WardrikChannel.Notices, ops}] =
             Enum.sort(Config.section(config, WardrikNotify)[:targets])

    assert ops[:channel] == {WardrikDaemon.Test.Channel, []}

    # What a channel's medium sends it over HTTP is answered by the channel.
    {:ok, port} = WardrikHTTP.Listener.port()

    assert {:ok, %{status: 200}} =
             Req.post("http://127.0.0.1:#{port}/v1/channels/chat/events", body: "", retry: false)

    assert {:ok, %{status: 404}} =
             Req.post("http://127.0.0.1:#{port}/v1/channels/other/events", body: "", retry: false)
  end

  test "reads config.yml where that is the file there", %{tmp_dir: dir} do
    key = WardrikVault.generate_key()
    File.write!(Path.join(dir, "config.yml"), "vault:\n  keys: [\"#{key}\"]\n")

    assert {{:ok, _pid}, _config, host} = daemon(dir)

    assert Wardrik.Host.credentials(host).keys == [key]
  end

  test "refuses a config directory holding both config.yaml and config.yml", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "config.yaml"), "")
    File.write!(Path.join(dir, "config.yml"), "")

    assert {:error, message} = load(dir)

    assert message =~ "holds both config.yaml and config.yml; keep one"
  end

  test "reads a ${NAME} the environment does not set from the vault", %{tmp_dir: dir} do
    :ok = Settings.vault()
    name = "DAEMON_TEST_IP_#{System.unique_integer([:positive])}"
    :ok = WardrikVault.put(Settings.held_vault(), name, nil, value: "127.0.0.1")
    on_exit(fn -> WardrikVault.forget(Settings.held_vault(), name, nil) end)

    File.write!(Path.join(dir, "config.yaml"), "ssh:\n  ip: \"${#{name}}\"\n")

    assert {{:ok, _pid}, config, _host} = daemon(dir)

    assert Config.section(config, WardrikDaemon.SSH)[:ip] == {127, 0, 0, 1}
  end

  test "reads storage from the environment alone, and says why it stops", %{tmp_dir: dir} do
    :ok = Settings.vault()
    name = "DAEMON_TEST_DB_#{System.unique_integer([:positive])}"

    :ok =
      WardrikVault.put(Settings.held_vault(), name, nil, value: "postgres://localhost/wardrik")

    on_exit(fn -> WardrikVault.forget(Settings.held_vault(), name, nil) end)

    File.write!(Path.join(dir, "config.yaml"), "storage:\n  postgres:\n    url: \"${#{name}}\"\n")

    assert {:error, message} = load(dir)

    assert message =~
             "storage.postgres.url names ${#{name}}, which is not set; storage reads " <>
               "the environment alone, since the vault is kept in the store"
  end

  test "a config.yaml that does not read stops it, and says why", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "config.yaml"), "nope: {}\n")

    assert {:error, message} = load(dir)

    assert message =~ "nope is not a section"
  end

  test "status/0 shows what a budgeted agent has spent", %{tmp_dir: dir} do
    org = "status-#{System.unique_integer([:positive])}"
    on_exit(fn -> Wardrik.Fleet.forget_under(Prefix.parse!(org <> "/")) end)

    File.write!(Path.join(dir, "config.yaml"), "orgs:\n  #{org}: {}\n")
    File.mkdir_p!(Path.join(dir, "agents"))

    File.write!(
      Path.join([dir, "agents", "counter.md"]),
      "---\norg: #{org}\npolicy:\n  budget:\n    tokens: 500\n---\nYou count.\n"
    )

    {{:ok, _pid}, config, host} = daemon(dir)

    Wardrik.Test.Fleet.await_update(fn ->
      Enum.any?(Wardrik.Fleet.list(Prefix.parse!(org <> "/")))
    end)

    assert WardrikDaemon.status(host, config) =~
             "#{org}/counter  idle  #{node()}  0 of 500 tokens today"
  end

  test "status/0 names the node and counts the fleet", %{tmp_dir: dir} do
    agents = Host.start_agents(dir)
    status = WardrikDaemon.status(Host.host(agents), Host.config(dir))

    assert status =~ "on #{node()}, up "
    assert status =~ ~r/\d+ agents?/
  end
end
