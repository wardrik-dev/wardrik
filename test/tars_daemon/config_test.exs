defmodule TarsDaemon.ConfigTest do
  use ExUnit.Case, async: false

  alias TarsDaemon.Config

  @moduletag :tmp_dir

  defp read(yaml, %{tmp_dir: dir}) do
    file = Path.join(dir, "config.yaml")
    File.write!(file, yaml)
    Config.read(file)
  end

  defp env(value) do
    name = "TARS_CONFIG_TEST_#{System.unique_integer([:positive])}"
    System.put_env(name, value)
    on_exit(fn -> System.delete_env(name) end)
    name
  end

  describe "read/1" do
    test "a missing file configures nothing", %{tmp_dir: dir} do
      assert {:ok, []} = Config.read(Path.join(dir, "config.yaml"))
    end

    test "an empty file configures nothing", context do
      assert {:ok, []} = read("", context)
    end

    test "a server with a command is started as one", context do
      assert {:ok, [{TarsMCP, servers: [notes: server]}]} =
               read(
                 """
                 mcp:
                   notes:
                     command: npx
                     args: [-y, server-filesystem]
                     env:
                       ROOT: /srv/notes
                     only: [read_file]
                     timeout: 30
                 """,
                 context
               )

      assert server[:transport] ==
               {:stdio,
                command: "npx", args: ["-y", "server-filesystem"], env: %{"ROOT" => "/srv/notes"}}

      assert server[:only] == ["read_file"]
      assert server[:timeout] == 30_000
    end

    test "a server with a url is reached over HTTP, as the user it names", context do
      assert {:ok, [{TarsMCP, servers: [github: server]}]} =
               read(
                 """
                 mcp:
                   github:
                     url: https://api.githubcopilot.com/mcp/
                     headers:
                       x-team: core
                     credential: user:github
                 """,
                 context
               )

      assert server[:transport] ==
               {:streamable_http,
                base_url: "https://api.githubcopilot.com/mcp/", headers: %{"x-team" => "core"}}

      assert server[:credential] == {:user, "github"}
    end

    test "${NAME} is read from the environment", context do
      name = env("lin_secret")

      assert {:ok, [{TarsMCP, servers: [linear: server]}]} =
               read(
                 """
                 mcp:
                   linear:
                     url: https://mcp.linear.app/mcp
                     headers:
                       authorization: Bearer ${#{name}}
                 """,
                 context
               )

      assert {:streamable_http, opts} = server[:transport]
      assert opts[:headers] == %{"authorization" => "Bearer lin_secret"}
    end

    test "oauth and vault settings keep their shape", context do
      key = env("a-vault-key")

      assert {:ok, settings} =
               read(
                 """
                 oauth:
                   client:
                     name: Acme agents
                   providers:
                     github:
                       resource: https://api.githubcopilot.com/mcp/
                       client_id: abc
                       scopes: [repo]
                 vault:
                   keys: ["${#{key}}"]
                 """,
                 context
               )

      oauth = Keyword.fetch!(settings, TarsOAuth)
      assert oauth[:client] == [name: "Acme agents"]
      assert oauth[:providers][:github][:scopes] == ["repo"]
      assert Keyword.fetch!(settings, TarsVault) == [keys: ["a-vault-key"]]
    end

    test "a variable that is not set says which value names it", context do
      assert {:error, message} =
               read(~s(vault:\n  keys: ["${TARS_CONFIG_TEST_UNSET}"]\n), context)

      assert message =~ "vault.keys.0 names ${TARS_CONFIG_TEST_UNSET}, which is not set"
    end

    test "a key nothing takes is refused", context do
      assert {:error, message} =
               read("mcp:\n  notes:\n    command: npx\n    comand: typo\n", context)

      assert message =~ "mcp.notes.comand is not a setting"
    end

    test "a server is a command or a url, not both and not neither", context do
      assert {:error, both} = read("mcp:\n  a:\n    command: x\n    url: https://x\n", context)
      assert both =~ "mcp.a has both command and url"

      assert {:error, neither} = read("mcp:\n  b:\n    only: [x]\n", context)
      assert neither =~ "mcp.b needs a command or a url"
    end

    test "a server's name or prefix may not hold __", context do
      assert {:error, named} = read("mcp:\n  my__notes:\n    command: npx\n", context)
      assert named =~ "mcp.my__notes names its tools with my__notes"

      assert {:error, prefixed} =
               read("mcp:\n  notes:\n    command: npx\n    prefix: my__notes\n", context)

      assert prefixed =~ "mcp.notes names its tools with my__notes"
    end

    test "a credential is user:, org: or named:", context do
      assert {:error, message} =
               read("mcp:\n  a:\n    url: https://x\n    credential: github\n", context)

      assert message =~ "mcp.a.credential is user:NAME, org:NAME or named:NAME"
    end

    test "ssh moves the listener", context do
      assert {:ok, [{TarsDaemon.SSH, ssh}]} = read("ssh:\n  port: 2022\n  ip: 0.0.0.0\n", context)
      assert ssh[:port] == 2022
      assert ssh[:ip] == {0, 0, 0, 0}

      assert {:error, port} = read("ssh:\n  port: 70000\n", context)
      assert port =~ "ssh.port is a port number"
      assert {:error, ip} = read("ssh:\n  ip: nowhere\n", context)
      assert ip =~ "ssh.ip is an address"
    end

    test "notify names targets, each Slack or a webhook", context do
      yaml = """
      notify:
        ops:
          slack:
            channel: "#ops"
            token: xoxb-1
            app_token: xapp-1
            approvers: [U1]
        audit:
          webhook:
            url: https://hooks.example.com/tars
      """

      assert {:ok, [{TarsNotify, notify}]} = read(yaml, context)

      assert Enum.sort(notify[:targets]) == [
               audit: {TarsNotify.Webhook, [url: "https://hooks.example.com/tars"]},
               ops:
                 {TarsNotify.Slack,
                  [app_token: "xapp-1", approvers: ["U1"], channel: "#ops", token: "xoxb-1"]}
             ]
    end

    test "a notify target that does not read says where", context do
      assert {:error, message} = read("notify:\n  ops:\n    email: {to: a}\n", context)
      assert message =~ "notify.ops is one of slack or webhook"

      assert {:error, message} = read("notify:\n  ops:\n    slack: {channel: x}\n", context)
      assert message =~ "notify.ops.slack.token is required"

      assert {:error, message} =
               read("notify:\n  ops:\n    webhook: {url: x, colour: red}\n", context)

      assert message =~ "notify.ops.webhook.colour is not a setting"
    end

    test "file/1 finds config.yaml or config.yml, and refuses both", %{tmp_dir: dir} do
      assert Config.file(dir) == {:ok, Path.join(dir, "config.yaml")}

      File.write!(Path.join(dir, "config.yml"), "")
      assert Config.file(dir) == {:ok, Path.join(dir, "config.yml")}

      File.write!(Path.join(dir, "config.yaml"), "")
      assert {:error, message} = Config.file(dir)
      assert message =~ "both config.yaml and config.yml"
    end

    test "an unknown section is refused", context do
      assert {:error, message} = read("agents:\n  x: 1\n", context)
      assert message =~ "agents is not a section"
    end

    test "a file that is not a set of sections says so", context do
      assert {:error, message} = read("- a\n- b\n", context)
      assert message =~ "the file is a set of sections"
    end

    test "a file that is not YAML says so", context do
      assert {:error, message} = read("mcp: [a\n", context)
      assert message =~ "config.yaml: is not YAML"
    end
  end

  describe "the directories" do
    @describetag tmp_dir: false

    setup do
      saved =
        Map.new(
          ~w(TARS_CONFIG_DIR TARS_STATE_DIR XDG_CONFIG_HOME XDG_STATE_HOME),
          &{&1, System.get_env(&1)}
        )

      Enum.each(saved, fn {name, _value} -> System.delete_env(name) end)

      on_exit(fn ->
        Enum.each(saved, fn
          {name, nil} -> System.delete_env(name)
          {name, value} -> System.put_env(name, value)
        end)
      end)
    end

    test "follow the XDG base directories" do
      assert Config.config_dir() == Path.expand("~/.config/tars")
      assert Config.state_dir() == Path.expand("~/.local/state/tars")

      System.put_env("XDG_CONFIG_HOME", "/xdg/config")
      System.put_env("XDG_STATE_HOME", "/xdg/state")

      assert Config.config_dir() == "/xdg/config/tars"
      assert Config.state_dir() == "/xdg/state/tars"
    end

    test "are each overridden by their own variable" do
      System.put_env("XDG_CONFIG_HOME", "/xdg/config")
      System.put_env("TARS_CONFIG_DIR", "/etc/tars")
      System.put_env("TARS_STATE_DIR", "/var/lib/tars")

      assert Config.config_dir() == "/etc/tars"
      assert Config.state_dir() == "/var/lib/tars"
    end
  end

  describe "apply/1" do
    test "merges over what the package already holds" do
      package = :"Elixir.TarsDaemon.ConfigTest.Package#{System.unique_integer([:positive])}"
      Application.put_env(:tars, package, kept: 1, replaced: 1)
      on_exit(fn -> Application.delete_env(:tars, package) end)

      :ok = Config.apply([{package, replaced: 2}])

      assert Application.get_env(:tars, package) == [kept: 1, replaced: 2]
    end
  end
end
