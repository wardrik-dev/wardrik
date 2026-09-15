defmodule Tars.Test.Fleet do
  @moduledoc """
  Starts agents in the fleet under keys unique to the test, and forgets them
  afterwards so nothing is left in the store.
  """

  alias Tars.Fleet

  @doc "Starts an agent and returns its key and pid."
  @spec start_agent(keyword()) :: {String.t(), pid()}
  def start_agent(opts \\ []) do
    key = key()
    {:ok, pid} = Fleet.spawn(key, opts)
    ExUnit.Callbacks.on_exit(fn -> Fleet.forget(key) end)

    {key, pid}
  end

  @doc "A key nothing else in the suite will use."
  @spec key(String.t()) :: String.t()
  def key(name \\ "agent") do
    "test/#{System.unique_integer([:positive])}/#{name}"
  end
end
