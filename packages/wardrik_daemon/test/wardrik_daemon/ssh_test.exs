defmodule WardrikDaemon.SSHTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias WardrikDaemon.SSH

  @moduletag :tmp_dir

  @host Wardrik.Host.new()

  # The daemon's config reading `config` and writing under `data`, with what
  # the release says of SSH, as a release with the TUI says it.
  defp config(config, data, ssh \\ [entrypoint: {WardrikTUI.SSH, []}]) do
    WardrikDaemon.Config.new(
      config_dir: config,
      data_dir: data,
      state_dir: data,
      sections: [{SSH, ssh}]
    )
  end

  defp public_key(dir, comment) do
    path = Path.join(dir, "key-#{System.unique_integer([:positive])}")
    {_out, 0} = System.cmd("ssh-keygen", ~w(-q -t ed25519 -N) ++ ["", "-f", path, "-C", comment])
    contents = File.read!(path <> ".pub")
    [{key, _attrs}] = :ssh_file.decode(contents, :auth_keys)
    {contents, key}
  end

  test "listens only once the config directory holds keys", %{tmp_dir: dir} do
    assert SSH.children(config(Path.join(dir, "config"), Path.join(dir, "data")), host: @host) ==
             []
  end

  test "with keys but nothing to serve, as in a build without the TUI, says so and listens nowhere",
       %{tmp_dir: dir} do
    config = Path.join(dir, "config")
    File.mkdir_p!(Path.join(config, "ssh"))
    File.write!(Path.join([config, "ssh", "authorized_keys"]), "")

    log =
      capture_log(fn ->
        assert SSH.children(config(config, Path.join(dir, "data"), port: 2222), host: @host) == []
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

    assert [{SSH, opts}] = SSH.children(config(config, Path.join(dir, "data")), host: @host)
    assert opts[:port] == 2222
    assert opts[:ip] == {127, 0, 0, 1}
    assert {:public_key, verifier} = opts[:auth]
    assert is_function(verifier, 2)
    assert {WardrikTUI.SSH, entrypoint} = opts[:entrypoint]
    assert entrypoint[:host] == @host

    host_key = Path.join([dir, "data", "ssh", "ssh_host_rsa_key"])
    assert mode(host_key) == 0o600
    assert mode(Path.dirname(host_key)) == 0o700
    written = File.read!(host_key)

    File.chmod!(host_key, 0o644)
    File.chmod!(Path.dirname(host_key), 0o755)
    SSH.children(config(config, Path.join(dir, "data")), host: @host)

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
    [{SSH, opts}] = SSH.children(config(config, Path.join(dir, "data")), host: @host)

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
    {listed, key} = public_key(dir, "jon@laptop")
    {_other, stranger} = public_key(dir, "stranger")

    File.write!(keys, listed)
    assert SSH.authorized?(keys, ~c"jon", key)
    refute SSH.authorized?(keys, ~c"jon", stranger)

    File.write!(keys, "")
    refute SSH.authorized?(keys, ~c"jon", key)
    refute SSH.authorized?(Path.join(dir, "missing"), ~c"jon", key)
  end

  test "a key logs in only as the names it is listed for", %{tmp_dir: dir} do
    keys = Path.join(dir, "authorized_keys")
    {listed, key} = public_key(dir, "jon@laptop")
    {named, ana} = public_key(dir, "ana@desk")
    {bare, nameless} = public_key(dir, "")

    File.write!(keys, listed <> ~s(no-pty,principals="ana,maria" ) <> named <> bare)

    assert SSH.authorized?(keys, ~c"jon", key)
    refute SSH.authorized?(keys, ~c"maria", key)
    assert SSH.authorized?(keys, ~c"maria", ana)
    assert SSH.authorized?(keys, "ana", ana)
    refute SSH.authorized?(keys, ~c"ana@desk", ana)
    refute SSH.authorized?(keys, ~c"", nameless)
    refute SSH.authorized?(keys, ~c"jon", nameless)
  end
end
