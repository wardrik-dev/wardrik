defmodule Wardrik.Interrupt do
  @moduledoc """
  A call an agent waits on a person for.

      {:waiting, [interrupt]} = Wardrik.Agent.reply(scope, "agt_1", "Refund order 1001.")
      Wardrik.Agent.approve(scope, interrupt: interrupt)

  `reason` is `:tool_approval`, `:model_approval`, `:ceiling_approval`, `:authorization` or
  `:in_doubt`. `agent` and `conversation` say where it waits. Given as `interrupt:`, it names
  them for you.
  """

  use Wardrik.Type,
    schema: ["defs", "$defs", "interrupt"],
    fields: [
      id: "id",
      reason:
        {"reason",
         [:tool_approval, :model_approval, :ceiling_approval, :authorization, :in_doubt]},
      message: "message",
      name: "name",
      tool_call_id: "tool_call_id",
      labels: "labels",
      agent: nil,
      conversation: nil
    ]

  @doc "Builds one from an `interrupts.list` item, with its `agent` and `conversation`."
  @spec from_listed(map()) :: t()
  def from_listed(%{"agent" => %{"id" => agent}, "interrupt" => interrupt} = listed),
    do: %{from_json(interrupt) | agent: agent, conversation: listed["conversation"]}
end
