defmodule WardrikDaemon.VaultKeyTest do
  use ExUnit.Case, async: false

  alias WardrikDaemon.Test.Settings
  alias WardrikDaemon.VaultKey

  @moduletag :tmp_dir

  setup do
    Settings.no_vault()
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

  test "gives the vault the file's key, readable by its owner alone", %{tmp_dir: dir} do
    assert VaultKey.keys(dir) == []

    {:ok, file} = VaultKey.make(dir)
    File.chmod!(file, 0o644)

    assert VaultKey.keys(dir) == [elem(VaultKey.read(file), 1)]
    assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600
  end

  test "says why a file holds no key, and makes none over it", %{tmp_dir: dir} do
    file = VaultKey.file(dir)
    File.write!(file, "c2hvcnQ=\n")

    assert {:error, message} = VaultKey.read(file)
    assert message =~ "#{file} holds no key the vault can use"
    assert VaultKey.make(dir) == {:error, message}
    assert VaultKey.keys(dir) == []
  end

  test "says why it cannot write one", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "data"), "")

    assert {:error, message} = VaultKey.make(Path.join(dir, "data"))
    assert message =~ "data/vault_key: not a directory"
  end
end
