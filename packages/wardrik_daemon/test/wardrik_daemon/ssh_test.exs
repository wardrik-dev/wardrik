defmodule WardrikDaemon.SSHTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias WardrikDaemon.SSH

  @moduletag :tmp_dir

  defp public_key(dir, name) do
    path = Path.join(dir, name)
    {_out, 0} = System.cmd("ssh-keygen", ~w(-q -t ed25519 -N) ++ ["", "-f", path, "-C", name])
    contents = File.read!(path <> ".pub")
    [{key, _attrs}] = :ssh_file.decode(contents, :auth_keys)
    {contents, key}
  end

  test "listens only once the config directory holds keys", %{tmp_dir: dir} do
    assert SSH.children(Path.join(dir, "config"), Path.join(dir, "data")) == []
  end

  test "with keys but nothing to serve, as in a build without the TUI, says so and listens nowhere",
       %{tmp_dir: dir} do
    config = Path.join(dir, "config")
    File.mkdir_p!(Path.join(config, "ssh"))
    File.write!(Path.join([config, "ssh", "authorized_keys"]), "")

    log =
      capture_log(fn ->
        assert SSH.children(config, Path.join(dir, "data"), port: 2222) == []
      end)

    assert log =~ "this build has no TUI"
    refute File.exists?(Path.join([dir, "data", "ssh"]))
  end

  test "with keys, listens on loopback with a host key made once and kept private", %{
    tmp_dir: dir
  } do
    config = Path.join(dir, "config")
    File.mkdir_p!(Path.join(config, "ssh"))
    File.write!(Path.join([config, "ssh", "authorized_keys"]), "")

    assert [{SSH, opts}] = SSH.children(config, Path.join(dir, "data"))
    assert opts[:port] == 2222
    assert opts[:ip] == {127, 0, 0, 1}
    assert {:public_key, verifier} = opts[:auth]
    assert is_function(verifier, 2)

    host_key = Path.join([dir, "data", "ssh", "ssh_host_rsa_key"])
    assert mode(host_key) == 0o600
    assert mode(Path.dirname(host_key)) == 0o700
    written = File.read!(host_key)

    File.chmod!(host_key, 0o644)
    File.chmod!(Path.dirname(host_key), 0o755)
    SSH.children(config, Path.join(dir, "data"))

    assert File.read!(host_key) == written
    assert mode(host_key) == 0o600
    assert mode(Path.dirname(host_key)) == 0o700
  end

  defp mode(path), do: path |> File.stat!() |> Map.fetch!(:mode) |> Bitwise.band(0o777)

  test "a port another process holds leaves SSH unserved until it is free, then serves it", %{
    tmp_dir: dir
  } do
    config = Path.join(dir, "config")
    File.mkdir_p!(Path.join(config, "ssh"))
    File.write!(Path.join([config, "ssh", "authorized_keys"]), "")
    [{SSH, opts}] = SSH.children(config, Path.join(dir, "data"))

    {:ok, held} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(held)
    opts = opts |> Keyword.delete(:name) |> Keyword.merge(port: port, retry: :timer.hours(1))

    log =
      capture_log(fn ->
        assert {:ok, supervisor} = Supervisor.start_link([{SSH, opts}], strategy: :one_for_one)
        assert [{SSH, listener, :worker, _modules}] = Supervisor.which_children(supervisor)
        assert {:waiting, _opts, _retry} = :sys.get_state(listener)

        :ok = :gen_tcp.close(held)
        send(listener, :listen)

        assert {:serving, _pid} = :sys.get_state(listener)
        assert {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [])
        :gen_tcp.close(socket)
      end)

    assert log =~ "SSH is not served: port #{port} on 127.0.0.1 could not be listened on"
  end

  test "a key is let in while the file lists it, read at every login", %{tmp_dir: dir} do
    keys = Path.join(dir, "authorized_keys")
    {listed, key} = public_key(dir, "listed")
    {_other, stranger} = public_key(dir, "stranger")

    File.write!(keys, listed)
    assert SSH.authorized?(keys, key)
    refute SSH.authorized?(keys, stranger)

    File.write!(keys, "")
    refute SSH.authorized?(keys, key)
    refute SSH.authorized?(Path.join(dir, "missing"), key)
  end
end
