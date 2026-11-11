defmodule Wardrik.Nodes do
  @moduledoc """
  The deployment's `nodes`, how many of the agents on them are `running`, `idle` or `parked`, and
  how many are `asleep`.
  """

  use Wardrik.Type,
    schema: ["nodes"],
    fields: [
      nodes: {"nodes", [Wardrik.Node]},
      running: "running",
      idle: "idle",
      parked: "parked",
      asleep: "asleep"
    ]
end

defmodule Wardrik.Node do
  @moduledoc "One of the deployment's nodes: its `name`, and how many `agents` run on it."

  use Wardrik.Type,
    schema: ["nodes", "properties", "nodes", "items"],
    fields: [name: "name", agents: "agents"]
end
