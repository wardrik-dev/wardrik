defmodule Wardrik.Interrupt do
  @moduledoc """
  A call an agent waits on a person for, by its `id`, and why: `:tool_approval`, `:model_approval`,
  `:ceiling_approval`, `:authorization` or `:in_doubt`. `agent_id` names the agent, where a list of many gives it.
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
      agent_id: nil
    ]

  @doc "Reads one from an item of `interrupts.list`, with the agent it's of."
  @spec from_listed(map()) :: t()
  def from_listed(%{"agent" => %{"id" => agent_id}, "interrupt" => interrupt}),
    do: %{from_json(interrupt) | agent_id: agent_id}
end
