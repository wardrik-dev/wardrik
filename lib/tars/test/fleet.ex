defmodule Tars.Test.Fleet do
  @moduledoc """
  Starts agents in the fleet under keys unique to the test, and forgets them
  afterwards so nothing is left in the store.
  """

  alias Tars.Fleet

  @doc "Waits for watched registry changes until the condition holds, without polling."
  def await_update(check) do
    await_update(check, System.monotonic_time(:millisecond) + 2_000)
  end

  defp await_update(check, deadline) do
    if check.() do
      true
    else
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:group, _events, _info} -> await_update(check, deadline)
      after
        remaining -> false
      end
    end
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
