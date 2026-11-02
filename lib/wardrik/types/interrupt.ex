defmodule Wardrik.Interrupt do
  @moduledoc """
  A call an agent waits on a person for.

  `reason` is `:tool_approval`, `:model_approval`, `:ceiling_approval`, `:authorization` or
  `:in_doubt`. `agent_id` and `conversation` are set only by `Wardrik.Interrupts.list/2`.
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
      agent_id: nil,
      conversation: nil
    ]

  @doc "Builds one from an `interrupts.list` item, with its `agent_id` and `conversation`."
  @spec from_listed(map()) :: t()
  def from_listed(%{"agent" => %{"id" => agent_id}, "interrupt" => interrupt} = listed),
    do: %{from_json(interrupt) | agent_id: agent_id, conversation: listed["conversation"]}
end
