defmodule Tars.Tether do
  @moduledoc """
  Ties the calling process to an owner it was not linked to: when the owner
  exits, for any reason, the caller is killed. Nothing travels the other way,
  so a caller that crashes leaves its owner running.

      Task.Supervisor.async_nolink(Tars.TaskSupervisor, fn ->
        Tars.Tether.to(owner)
        work()
      end)

  A turn is tethered to its agent, and each tool call to its turn, so an agent
  that stops or moves leaves nothing of its turn running.
  """

  @doc "Kills the calling process when `owner` exits."
  @spec to(pid()) :: :ok
  def to(owner) when is_pid(owner) do
    tethered = self()

    spawn(fn ->
      owner_ref = Process.monitor(owner)
      tethered_ref = Process.monitor(tethered)

      receive do
        {:DOWN, ^owner_ref, :process, _pid, _reason} -> Process.exit(tethered, :kill)
        {:DOWN, ^tethered_ref, :process, _pid, _reason} -> :ok
      end
    end)

    :ok
  end
end
