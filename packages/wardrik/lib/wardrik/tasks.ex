defmodule Wardrik.Tasks do
  @moduledoc """
  The task supervisors core runs its work under: each turn, each tool call,
  each workflow branch, and the trim of a log once a turn closes.

  They are a `PartitionSupervisor` of `Task.Supervisor`s, one per scheduler,
  so starting a task never queues behind every other start on the node.
  `supervisor/1` names the one a key falls to:

      Task.Supervisor.async_nolink(Wardrik.Tasks.supervisor(), fn -> work() end)

  The key is the calling process unless given, so the tasks of one caller
  share a supervisor and those of many callers are spread across them.
  """

  @doc false
  @spec child_spec([]) :: Supervisor.child_spec()
  def child_spec([]),
    do: PartitionSupervisor.child_spec(child_spec: Task.Supervisor, name: __MODULE__)

  @doc "The task supervisor `key` falls to, the calling process's unless given."
  @spec supervisor(term()) :: {:via, PartitionSupervisor, {module(), term()}}
  def supervisor(key \\ self()), do: {:via, PartitionSupervisor, {__MODULE__, key}}
end
