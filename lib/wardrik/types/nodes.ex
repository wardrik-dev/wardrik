defmodule Wardrik.Nodes do
  @moduledoc "The deployment's nodes, each with how many agents run on it, and how many agents sleep."

  use Wardrik.Type,
    schema: ["nodes"],
    fields: [nodes: {"nodes", [Wardrik.Node]}, asleep: "asleep"]
end

defmodule Wardrik.Node do
  @moduledoc "One of the deployment's nodes, by its `name`, and how many `agents` run on it."

  use Wardrik.Type,
    schema: ["nodes", "properties", "nodes", "items"],
    fields: [name: "name", agents: "agents"]
end
