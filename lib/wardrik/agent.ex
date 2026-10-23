defmodule Wardrik.Agent do
  @moduledoc """
  An agent, and the operations on one, from defining it and asking it to deciding what it waits on.

      {:ok, %Wardrik.Message{cursor: cursor}} = Wardrik.Agent.ask(scope, "acme/triage", "What's on fire?")
      {:ok, %Wardrik.Agent{status: :idle}} = Wardrik.Agent.read(scope, "acme/triage")

  An agent is its `id` and `name`, its `status`, `:idle`, `:running`, `:parked` or `:asleep`, the
  messages `pending` behind what it does, its `activity`, the `interrupts` it waits on a person
  for, and the `cursor` where its log stands. A list of agents leaves out what it doesn't read.
  """

  use Wardrik.Type,
    schema: ["agent_snapshot"],
    fields: [
      id: "agent.id",
      name: "agent.name",
      status: {"status", [:idle, :running, :parked, :asleep]},
      pending: "pending",
      activity: {"activity", Wardrik.Activity},
      interrupts: {"interrupts", [Wardrik.Interrupt]},
      cursor: "cursor"
    ]

  use Wardrik.Operations.Functions, prefix: "agent"

  @doc "Reads one from an agent as a list gives it."
  @spec from_summary(map()) :: t()
  def from_summary(%{"id" => id, "name" => name} = summary),
    do:
      from_json(%{
        "agent" => %{"id" => id, "name" => name},
        "status" => summary["status"],
        "pending" => summary["pending"]
      })
end
