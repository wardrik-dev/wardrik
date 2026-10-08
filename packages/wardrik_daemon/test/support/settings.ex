defmodule WardrikDaemon.Test.Settings do
  @moduledoc false
  # The daemon keeps what config.yaml says in its own application environment,
  # and starts the vault with it. A test that changes either has them put
  # back once it ends.

  import ExUnit.Callbacks, only: [on_exit: 1]

  def keep do
    daemon = Application.get_all_env(:wardrik_daemon)
    vault = WardrikVault.Config.settings()

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(:wardrik_daemon),
          not Keyword.has_key?(daemon, key),
          do: Application.delete_env(:wardrik_daemon, key)

      Application.put_all_env(wardrik_daemon: daemon)
      :ignore = WardrikVault.start_link(vault)
    end)
  end

  # A vault that seals with a key of its own, as the daemon would start it.
  def vault(keys \\ [WardrikVault.generate_key()]) do
    Application.put_env(:wardrik_daemon, WardrikVault, keys: keys)
    :ignore = WardrikVault.start_link(keys: keys)
    :ok
  end

  def no_vault do
    Application.delete_env(:wardrik_daemon, WardrikVault)
    :ignore = WardrikVault.start_link([])
    :ok
  end
end
