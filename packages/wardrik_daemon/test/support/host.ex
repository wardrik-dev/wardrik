defmodule WardrikDaemon.Test.Host do
  @moduledoc false
  # The host the suite's fleet was started with, as config/test.exs names
  # it, for a daemon a test starts and the commands it runs.

  def host, do: Wardrik.Test.host()

  # What a command run over rpc finds the daemon's host in.
  def held do
    ExUnit.Callbacks.start_supervised!({WardrikDaemon.Host, host()})
    :ok
  end
end
