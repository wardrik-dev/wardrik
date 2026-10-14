defmodule WardrikDaemon.Test.Settings do
  @moduledoc false
  # The vault a test's host unseals with, as config.yaml's vault would give
  # its keys; see WardrikDaemon.Test.Host.

  alias WardrikDaemon.Test.Host

  # A vault that seals with a key of its own, as the daemon would start it.
  def vault(keys \\ [WardrikVault.generate_key()]) do
    Host.put_section(WardrikVault, keys: keys)
    :ok
  end

  def no_vault do
    Host.put_section(WardrikVault, keys: [])
    :ok
  end

  # The test's vault, as its host holds it.
  def held_vault, do: Wardrik.Host.credentials(Host.host(Host.agents()))
end
