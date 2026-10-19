defmodule Wardrik.Turn.Signal do
  @moduledoc """
  What a `Wardrik.Turn`'s process is asked through its mailbox, and how the
  turn reads it.

  `yield/1` asks it to end at its next boundary, and `interrupt/1` to stop
  as soon as it can, mid-answer if need be. A turn reads them where it can
  stop: `stopping?/0` at a boundary, for either, and `interrupted?/1` where
  only a stop now will do.
  """

  @doc "Asks the process running a turn to stop once it reaches a boundary."
  @spec yield(pid()) :: :ok
  def yield(pid) when is_pid(pid) do
    send(pid, :yield)
    :ok
  end

  @doc "Asks the process running a turn to stop as soon as it can, mid-response if need be."
  @spec interrupt(pid()) :: :ok
  def interrupt(pid) when is_pid(pid) do
    send(pid, :interrupt)
    :ok
  end

  @doc "Whether this process has been asked to yield or to stop."
  @spec stopping?() :: boolean()
  def stopping? do
    receive do
      :yield -> true
      :interrupt -> true
    after
      0 -> false
    end
  end

  @doc "Whether this process is asked to stop within `ms`, waiting no longer."
  @spec interrupted?(timeout()) :: boolean()
  def interrupted?(ms \\ 0) do
    receive do
      :interrupt -> true
    after
      ms -> false
    end
  end
end
