defmodule Wardrik.Test.Fleet do
  @moduledoc """
  Starts agents in the fleet under keys unique to the test, and forgets them
  afterwards so nothing is left in the store.
  """

  alias Wardrik.Fleet

  @doc """
  Waits until `check` holds, asking it again at each change to the fleet, for
  up to two seconds. Answers whether it came to hold.

  The fleet is watched by a process of its own for as long as this waits, so
  the caller need not watch it, and any watch of the caller's keeps its own
  messages.
  """
  @spec await_update((-> as_boolean(term()))) :: boolean()
  def await_update(check) do
    caller = self()
    watcher = spawn_link(fn -> watch(caller) end)

    receive do
      {:watching, ^watcher} -> :ok
    end

    try do
      await_update(check, watcher, System.monotonic_time(:millisecond) + 2_000)
    after
      Process.unlink(watcher)
      Process.exit(watcher, :kill)
    end
  end

  defp await_update(check, watcher, deadline) do
    if check.() do
      true
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:fleet_changed, ^watcher} -> await_update(check, watcher, deadline)
      after
        remaining -> false
      end
    end
  end

  defp watch(caller) do
    :ok = Fleet.watch()
    send(caller, {:watching, self()})
    relay(caller)
  end

  defp relay(caller) do
    receive do
      {:group, _events, _info} -> send(caller, {:fleet_changed, self()})
    end

    relay(caller)
  end

  @doc "Starts an agent under `key` and returns the key and pid."
  @spec start_agent(keyword(), String.t()) :: {String.t(), pid()}
  def start_agent(opts \\ [], key \\ key()) do
    {:ok, pid} = Fleet.spawn(key, opts)
    ExUnit.Callbacks.on_exit(fn -> Fleet.forget(key) end)

    {key, pid}
  end

  @doc "A key nothing else in the suite will use, under the `test` org and no user."
  @spec key(String.t()) :: String.t()
  def key(name \\ "agent") do
    "test/_/#{name}-#{System.unique_integer([:positive])}"
  end
end
