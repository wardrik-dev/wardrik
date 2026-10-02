defmodule WardrikDaemon.VaultKeyTest do
  use ExUnit.Case, async: false

  alias WardrikDaemon.VaultKey

  @moduletag :tmp_dir

  setup do
    previous = Application.get_env(:wardrik_vault, WardrikVault)
    Application.delete_env(:wardrik_vault, WardrikVault)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:wardrik_vault, WardrikVault, previous),
        else: Application.delete_env(:wardrik_vault, WardrikVault)
    end)
  end

  test "makes a key once, readable by its owner alone, and keeps it", %{tmp_dir: dir} do
    assert {:ok, file} = VaultKey.make(dir)
    assert file == Path.join(dir, "vault_key")
    assert {:ok, key} = VaultKey.read(file)
    assert WardrikVault.key?(key)
    assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600

    assert {:ok, ^file} = VaultKey.make(dir)
    assert VaultKey.read(file) == {:ok, key}
    assert File.ls!(dir) == ["vault_key"]
  end

  test "makes one key where several make it at once", %{tmp_dir: dir} do
    made = 1..8 |> Task.async_stream(fn _n -> VaultKey.make(dir) end) |> Enum.to_list()

    assert Enum.uniq(made) == [ok: {:ok, VaultKey.file(dir)}]
    assert File.ls!(dir) == ["vault_key"]
  end

  test "gives the vault the file's key where nothing else gives it one", %{tmp_dir: dir} do
    assert VaultKey.load(dir) == :none
    refute WardrikVault.ready?()

    {:ok, file} = VaultKey.make(dir)
    File.chmod!(file, 0o644)

    assert VaultKey.load(dir) == :ok
    assert WardrikVault.ready?()
    assert WardrikVault.Config.keys() == [elem(VaultKey.read(file), 1)]
    assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600
  end

  test "leaves a key configured elsewhere in place", %{tmp_dir: dir} do
    configured = WardrikVault.generate_key()
    Application.put_env(:wardrik_vault, WardrikVault, keys: [configured])
    {:ok, _file} = VaultKey.make(dir)

    assert VaultKey.load(dir) == :ok
    assert WardrikVault.Config.keys() == [configured]
  end

  test "says why a file holds no key, and makes none over it", %{tmp_dir: dir} do
    file = VaultKey.file(dir)
    File.write!(file, "c2hvcnQ=\n")

    assert {:error, message} = VaultKey.load(dir)
    assert message =~ "#{file} holds no key the vault can use"
    assert VaultKey.make(dir) == {:error, message}
    refute WardrikVault.Config.configured?()
  end

  test "says why it cannot write one", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "data"), "")

    assert {:error, message} = VaultKey.make(Path.join(dir, "data"))
    assert message =~ "data/vault_key: not a directory"
  end
end
