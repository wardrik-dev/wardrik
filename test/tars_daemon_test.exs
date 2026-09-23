defmodule TarsDaemonTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup do
    previous = Application.get_env(:tars, TarsVault)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tars, TarsVault, previous),
        else: Application.delete_env(:tars, TarsVault)
    end)
  end

  test "starts with no config.toml at all", %{tmp_dir: dir} do
    assert {:ok, pid} = start_supervised({TarsDaemon, config_dir: dir, state_dir: dir})
    assert Supervisor.which_children(pid) == []
  end

  test "puts config.toml's settings where each package reads them", %{tmp_dir: dir} do
    key = TarsVault.generate_key()
    File.write!(Path.join(dir, "config.toml"), "[vault]\nkeys = [\"#{key}\"]\n")

    assert {:ok, _pid} = start_supervised({TarsDaemon, config_dir: dir, state_dir: dir})
    assert Application.get_env(:tars, TarsVault)[:keys] == [key]
  end

  test "a config.toml that does not read stops it, and says why", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "config.toml"), "[nope]\n")

    assert {:error, {{:config, message}, _child}} =
             start_supervised({TarsDaemon, config_dir: dir, state_dir: dir})

    assert message =~ "nope is not a section"
  end

  test "status/0 names the node and counts the fleet" do
    status = TarsDaemon.status()

    assert status =~ "on #{node()}, up "
    assert status =~ ~r/\d+ agents?/
  end
end
