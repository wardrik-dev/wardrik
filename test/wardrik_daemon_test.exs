defmodule WardrikDaemonTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup do
    previous = Application.get_env(:wardrik, WardrikVault)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wardrik, WardrikVault, previous),
        else: Application.delete_env(:wardrik, WardrikVault)
    end)
  end

  test "starts with no config.yaml at all, running the agent files and the HTTP API", %{
    tmp_dir: dir
  } do
    assert {:ok, pid} =
             start_supervised({WardrikDaemon, config_dir: dir, state_dir: dir, data_dir: dir})

    assert [WardrikDaemon.Agents, WardrikHTTP.Listener] =
             pid |> Supervisor.which_children() |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  test "defines the agents sent to its HTTP API as it reads agent files", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "policies"))
    File.write!(Path.join([dir, "policies", "careful.yaml"]), "deny: [run_lua]\n")

    {:ok, secret, _token} =
      WardrikHTTP.Token.create("daemon-test", "daemon/", Wardrik.Grant.actions(), ceiling: [])

    key = "daemon/defined-#{System.unique_integer([:positive])}"
    on_exit(fn -> Wardrik.Fleet.forget(key) end)

    start_supervised!({WardrikDaemon, config_dir: dir, state_dir: dir, data_dir: dir})
    {:ok, port} = WardrikHTTP.Listener.port()

    api =
      Req.new(
        base_url: "http://127.0.0.1:#{port}/v1/agents/#{key}",
        auth: {:bearer, secret},
        retry: false
      )

    assert {:ok, %{status: 400, body: body}} = Req.put(api, json: %{"policy" => "lax"})
    assert body["error"]["message"] == "policy names lax, which is not a policy in policies/"

    assert {:ok, %{status: 201}} =
             Req.put(api, json: %{"policy" => "careful", "instructions" => "You help."})

    assert Wardrik.Fleet.lookup(key)
    assert {:ok, %{status: 501}} = Req.get(api, url: "definition")

    assert {:ok, %{status: 204}} = Req.delete(api)
    assert Wardrik.Fleet.lookup(key) == nil
  end

  test "puts config.yaml's settings where each package reads them", %{tmp_dir: dir} do
    key = WardrikVault.generate_key()
    File.write!(Path.join(dir, "config.yaml"), "vault:\n  keys: [\"#{key}\"]\n")

    assert {:ok, _pid} =
             start_supervised({WardrikDaemon, config_dir: dir, state_dir: dir, data_dir: dir})

    assert Application.get_env(:wardrik, WardrikVault)[:keys] == [key]
  end

  test "reads config.yml where that is the file there", %{tmp_dir: dir} do
    key = WardrikVault.generate_key()
    File.write!(Path.join(dir, "config.yml"), "vault:\n  keys: [\"#{key}\"]\n")

    assert {:ok, _pid} =
             start_supervised({WardrikDaemon, config_dir: dir, state_dir: dir, data_dir: dir})

    assert Application.get_env(:wardrik, WardrikVault)[:keys] == [key]
  end

  test "refuses a config directory holding both config.yaml and config.yml", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "config.yaml"), "")
    File.write!(Path.join(dir, "config.yml"), "")

    assert {:error, {{:config, message}, _child}} =
             start_supervised({WardrikDaemon, config_dir: dir, state_dir: dir, data_dir: dir})

    assert message =~ "holds both config.yaml and config.yml; keep one"
  end

  test "reads a ${NAME} the environment does not set from the vault", %{tmp_dir: dir} do
    http = Application.get_env(:wardrik, WardrikHTTP)
    Application.put_env(:wardrik, WardrikVault, keys: [WardrikVault.generate_key()])
    name = "DAEMON_TEST_IP_#{System.unique_integer([:positive])}"
    :ok = WardrikVault.put({:named, name}, nil, "127.0.0.1")

    on_exit(fn ->
      WardrikVault.forget({:named, name}, nil)
      Application.put_env(:wardrik, WardrikHTTP, http)
    end)

    File.write!(Path.join(dir, "config.yaml"), "http:\n  ip: \"${#{name}}\"\n")

    assert {:ok, _pid} =
             start_supervised({WardrikDaemon, config_dir: dir, state_dir: dir, data_dir: dir})

    assert Application.get_env(:wardrik, WardrikHTTP)[:ip] == {127, 0, 0, 1}
  end

  test "reads storage from the environment alone, and says why it stops", %{tmp_dir: dir} do
    Application.put_env(:wardrik, WardrikVault, keys: [WardrikVault.generate_key()])
    name = "DAEMON_TEST_DB_#{System.unique_integer([:positive])}"
    :ok = WardrikVault.put({:named, name}, nil, "postgres://localhost/wardrik")
    on_exit(fn -> WardrikVault.forget({:named, name}, nil) end)

    File.write!(Path.join(dir, "config.yaml"), "storage:\n  postgres:\n    url: \"${#{name}}\"\n")

    assert {:error, {{:config, message}, _child}} =
             start_supervised({WardrikDaemon, config_dir: dir, state_dir: dir, data_dir: dir})

    assert message =~
             "storage.postgres.url names ${#{name}}, which is not set; storage reads " <>
               "the environment alone, since the vault is kept in the store"
  end

  test "a config.yaml that does not read stops it, and says why", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "config.yaml"), "nope: {}\n")

    assert {:error, {{:config, message}, _child}} =
             start_supervised({WardrikDaemon, config_dir: dir, state_dir: dir, data_dir: dir})

    assert message =~ "nope is not a section"
  end

  test "status/0 shows what a budgeted agent has spent", %{tmp_dir: dir} do
    org = "status-#{System.unique_integer([:positive])}"
    on_exit(fn -> Wardrik.Fleet.forget_under(org <> "/") end)

    File.mkdir_p!(Path.join(dir, "agents"))

    File.write!(
      Path.join([dir, "agents", "counter.md"]),
      "---\norg: #{org}\npolicy:\n  budget:\n    tokens: 500\n---\nYou count.\n"
    )

    start_supervised!({WardrikDaemon, config_dir: dir, state_dir: dir, data_dir: dir})

    Wardrik.Test.Fleet.await_update(fn -> Enum.any?(Wardrik.Fleet.list(org <> "/")) end)
    assert WardrikDaemon.status() =~ "#{org}/counter  idle  #{node()}  0 of 500 tokens today"
  end

  test "status/0 names the node and counts the fleet" do
    status = WardrikDaemon.status()

    assert status =~ "on #{node()}, up "
    assert status =~ ~r/\d+ agents?/
  end
end
