defmodule Tars.Test.RecordingScreen do
  @moduledoc """
  A `Tars.TUI.Screen` that forwards every call to the process registered under
  its own name, so tests can assert on what the TUI drew without a terminal.
  """

  @behaviour Tars.TUI.Screen

  @doc "Route screen calls to the calling process. Idempotent."
  def attach do
    case Process.whereis(__MODULE__) do
      nil -> Process.register(self(), __MODULE__)
      pid when pid == self() -> true
      _other -> Process.register(self(), __MODULE__)
    end

    :ok
  end

  defp record(event) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> send(pid, {:screen, event})
    end

    :ok
  end

  @impl true
  def open(rows), do: record({:open, rows})

  @impl true
  def close(rows), do: record({:close, rows})

  @impl true
  def write(data), do: record({:write, data})

  @impl true
  def status(data, _rows), do: record({:status, data})

  @impl true
  def clear_status(_rows), do: record(:clear_status)
end
