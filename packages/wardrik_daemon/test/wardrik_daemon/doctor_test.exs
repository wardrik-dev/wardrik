defmodule WardrikDaemon.DoctorTest do
  use ExUnit.Case, async: false

  alias Wardrik.Test.Services
  alias WardrikDaemon.Doctor

  @moduletag :tmp_dir

  defp config(dir, yaml), do: File.write!(Path.join(dir, "config.yaml"), yaml)

  setup %{tmp_dir: dir} do
    for {variable, value} <- [
          {"WARDRIK_DATA_DIR", Path.join(dir, "store")},
          {"WARDRIK_DATA_HOME", dir}
        ] do
      previous = System.get_env(variable)
      System.put_env(variable, value)

      on_exit(fn ->
        if previous,
          do: System.put_env(variable, previous),
          else: System.delete_env(variable)
      end)
    end

    :ok
  end

  test "checks that config.yaml reads, and the store it names", %{tmp_dir: dir} do
    config(dir, "cluster:\n  nodes: [a, b, c]\n")
    File.mkdir_p!(Path.join(dir, "store"))

    assert Doctor.checks(dir) == [
             {:ok, "config", "#{dir}/config.yaml reads"},
             {:ok, "store", "on this node's disk, at #{dir}/store"},
             {:ok, "vault", "no key, and nothing configured needs one"},
             {:ok, "agents", "no agent files in #{dir}/agents"}
           ]
  end

  test "a config.yaml that does not read is the only check", %{tmp_dir: dir} do
    config(dir, "storage:\n  s3: {}\n")

    assert [{:error, "config", message}] = Doctor.checks(dir)
    assert message =~ "storage.s3.bucket is required"
  end

  test "a directory holding config.yaml and config.yml fails", %{tmp_dir: dir} do
    config(dir, "")
    File.write!(Path.join(dir, "config.yml"), "")

    assert [{:error, "config", message}] = Doctor.checks(dir)
    assert message =~ "holds both config.yaml and config.yml"
  end

  @tag :postgres
  test "reaches the database storage names, and says why it cannot", %{tmp_dir: dir} do
    config(dir, "storage:\n  postgres:\n    url: #{Services.database_url()}\n")

    assert [{:ok, "config", _read}, {:ok, "store", found} | _rest] = Doctor.checks(dir)
    assert found =~ "holds wardrik_records"

    wrong = String.replace(Services.database_url(), ":postgres@", ":wrong@")
    config(dir, "storage:\n  postgres:\n    url: #{wrong}\n")

    assert [{:ok, "config", _read}, {:error, "store", found} | _rest] = Doctor.checks(dir)
    assert found =~ "password authentication failed"
  end

  defp check(checks, name), do: Enum.find(checks, &(elem(&1, 1) == name))

  describe "config.yaml's names from the vault" do
    setup %{tmp_dir: dir} do
      config(dir, """
      mcp:
        linear:
          command: sh
          env: {LINEAR_TOKEN: "${DOCTOR_LINEAR_TOKEN}"}
        zapier:
          url: "https://mcp.zapier.com/${DOCTOR_ZAPIER_PATH}/mcp"
      """)
    end

    test "are read from the vault of the daemon that runs", %{tmp_dir: dir} do
      {:ok, closing} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, closed} = :inet.port(closing)
      :ok = :gen_tcp.close(closing)

      config(dir, """
      mcp:
        linear:
          command: sh
          env: {LINEAR_TOKEN: "${DOCTOR_LINEAR_TOKEN}"}
        zapier:
          url: "http://127.0.0.1:#{closed}/${DOCTOR_ZAPIER_PATH}/mcp"
      """)

      vault = fn
        "DOCTOR_LINEAR_TOKEN" -> "lin_secret"
        "DOCTOR_ZAPIER_PATH" -> "s/abc"
      end

      checks = Doctor.checks(dir, vault)

      assert check(checks, "config") ==
               {:ok, "config",
                "#{dir}/config.yaml reads, with ${DOCTOR_LINEAR_TOKEN} and " <>
                  "${DOCTOR_ZAPIER_PATH} from the vault"}

      assert {:error, "mcp zapier", "127.0.0.1:" <> _does_not_answer} =
               check(checks, "mcp zapier")
    end

    test "fail where the vault does not hold one", %{tmp_dir: dir} do
      vault = fn
        "DOCTOR_LINEAR_TOKEN" -> "lin_secret"
        _other -> nil
      end

      assert [{:error, "config", message}] = Doctor.checks(dir, vault)

      assert message =~
               "names ${DOCTOR_ZAPIER_PATH}, which neither the environment nor the vault sets"
    end

    test "read as written where no daemon runs, and say so", %{tmp_dir: dir} do
      checks = Doctor.checks(dir)

      assert {:ok, "config", found} = check(checks, "config")
      assert found =~ "from the vault, which doctor reads only while the daemon runs"

      assert {:ok, "mcp zapier", "reads its url from the vault" <> _rest} =
               check(checks, "mcp zapier")

      config(dir, "http:\n  ip: \"${DOCTOR_HTTP_IP}\"\n")

      assert [{:error, "config", message}] = Doctor.checks(dir)
      assert message =~ "http.ip is an address"
      assert message =~ "It reads ${DOCTOR_HTTP_IP} from the vault, which doctor reads only"
    end
  end

  describe "the vault" do
    test "has keys it can use", %{tmp_dir: dir} do
      config(
        dir,
        "vault:\n  keys: [\"#{WardrikVault.generate_key()}\", \"#{WardrikVault.generate_key()}\"]\n"
      )

      assert check(Doctor.checks(dir), "vault") ==
               {:ok, "vault", "2 keys: the first seals, and any of them unseals"}
    end

    test "fails a key the vault cannot use", %{tmp_dir: dir} do
      config(dir, "vault:\n  keys: [\"#{WardrikVault.generate_key()}\", \"c2hvcnQ=\"]\n")

      assert {:error, "vault", "key 2 is not 32 bytes in base64" <> _how} =
               check(Doctor.checks(dir), "vault")
    end

    test "reads the key file in the data home where nothing else names a key", %{tmp_dir: dir} do
      {:ok, file} = WardrikDaemon.VaultKey.make(dir)

      assert check(Doctor.checks(dir), "vault") == {:ok, "vault", "1 key, from #{file}"}

      File.write!(file, "c2hvcnQ=\n")

      assert {:error, "vault", message} = check(Doctor.checks(dir), "vault")

      assert message ==
               "#{file} holds no key the vault can use: 32 bytes in base64, as openssl rand -base64 32 makes"
    end

    test "fails where a credential needs a key and there is none", %{tmp_dir: dir} do
      config(
        dir,
        "mcp:\n  github:\n    url: http://127.0.0.1:1/mcp\n    credential: github\n"
      )

      assert {:error, "vault", "no key, and mcp.github's credential needs one" <> how} =
               check(Doctor.checks(dir), "vault")

      assert how =~ "wardrik vault put makes one"
    end
  end

  describe "each MCP server" do
    test "runs a program this machine has, and fails one it does not", %{tmp_dir: dir} do
      config(dir, """
      mcp:
        here: {command: sh}
        gone: {command: wardrik-no-such-program}
      """)

      checks = Doctor.checks(dir)

      assert {:ok, "mcp here", "runs sh, at " <> _path} = check(checks, "mcp here")

      assert check(checks, "mcp gone") ==
               {:error, "mcp gone",
                "runs wardrik-no-such-program, which is not on this machine's PATH"}
    end

    test "is reached where it is served, and says why it is not", %{tmp_dir: dir} do
      {:ok, listening} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, open} = :inet.port(listening)
      {:ok, closing} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
      {:ok, closed} = :inet.port(closing)
      :ok = :gen_tcp.close(closing)

      config(dir, """
      vault:
        keys: ["#{WardrikVault.generate_key()}"]
      oauth:
        providers:
          github: {resource: "https://api.githubcopilot.com/mcp/"}
      mcp:
        up:
          url: http://127.0.0.1:#{open}/mcp
          credential: github
        kept:
          url: http://127.0.0.1:#{open}/mcp
          credential: pagerduty
        down: {url: "http://127.0.0.1:#{closed}/mcp"}
      """)

      checks = Doctor.checks(dir)

      assert check(checks, "mcp up") ==
               {:ok, "mcp up",
                "answers at 127.0.0.1:#{open}; credential github, from the vault, or an account each user connects"}

      assert check(checks, "mcp kept") ==
               {:ok, "mcp kept",
                "answers at 127.0.0.1:#{open}; credential pagerduty, from the vault"}

      assert check(checks, "mcp down") ==
               {:error, "mcp down",
                "127.0.0.1:#{closed} does not answer: the connection was refused"}
    end
  end

  describe "the agent files" do
    test "read, with the policies they name", %{tmp_dir: dir} do
      config(dir, "")
      File.mkdir_p!(Path.join(dir, "agents"))
      File.mkdir_p!(Path.join(dir, "policies"))
      File.write!(Path.join(dir, "policies/careful.yaml"), "ask: [run_lua]\n")
      File.write!(Path.join(dir, "agents/triage.md"), "---\npolicy: careful\n---\nYou help.\n")

      assert check(Doctor.checks(dir), "agents") ==
               {:ok, "agents", "1 agent file and 1 policy read"}
    end

    test "fail a line for each file that does not read", %{tmp_dir: dir} do
      config(dir, "")
      File.mkdir_p!(Path.join(dir, "agents"))
      File.write!(Path.join(dir, "agents/good.md"), "You help.\n")
      File.write!(Path.join(dir, "agents/bad.md"), "---\norg: acme/eu\n---\nYou help.\n")
      File.write!(Path.join(dir, "agents/worse.md"), "---\npolicy: missing\n---\nYou help.\n")

      assert [{:error, "agents", bad}, {:error, "agents", worse}] =
               Enum.filter(Doctor.checks(dir), &(elem(&1, 1) == "agents"))

      assert bad =~ "bad.md"
      assert worse =~ "worse.md"
    end
  end

  test "reports a check a line, marked by how it went" do
    assert Doctor.report([
             {:ok, "config", "/c/config.yaml reads"},
             {:error, "store", "the bucket b at https://s3: the bucket answered 403"}
           ]) ==
             "ok    config  /c/config.yaml reads\n" <>
               "FAIL  store   the bucket b at https://s3: the bucket answered 403"
  end
end
