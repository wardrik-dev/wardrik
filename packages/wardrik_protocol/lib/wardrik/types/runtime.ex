defmodule Wardrik.Runtime do
  @moduledoc """
  What `deployment.runtime` returns: resource use for each node in `nodes`, and the running
  agents that use the most memory in `agents`.
  """

  use Wardrik.Type,
    schema: ["runtime"],
    fields: [nodes: {"nodes", [Wardrik.NodeRuntime]}, agents: {"agents", [Wardrik.AgentRuntime]}]
end

defmodule Wardrik.NodeRuntime do
  @moduledoc """
  Resource use of one node.

  `memory`, `processes`, `ports`, `atoms`, `ets_tables`, `garbage_collections`, `io` and `os`
  are maps with string keys, as the protocol's JSON has them. `process_groups` is a list of such
  maps. `os` is `nil` unless the os_mon
  application runs on the node.
  """

  use Wardrik.Type,
    schema: ["runtime", "properties", "nodes", "items"],
    fields: [
      name: "name",
      agents: "agents",
      uptime_ms: "uptime_ms",
      otp_release: "otp_release",
      erts_version: "erts_version",
      elixir_version: "elixir_version",
      architecture: "architecture",
      logical_processors: "logical_processors",
      schedulers: "schedulers",
      schedulers_online: "schedulers_online",
      dirty_cpu_schedulers: "dirty_cpu_schedulers",
      dirty_io_schedulers: "dirty_io_schedulers",
      scheduler_utilization: "scheduler_utilization",
      run_queue: "run_queue",
      memory: "memory",
      process_groups: "process_groups",
      processes: "processes",
      ports: "ports",
      atoms: "atoms",
      ets_tables: "ets_tables",
      reductions: "reductions",
      garbage_collections: "garbage_collections",
      io: "io",
      context_switches: "context_switches",
      connected_nodes: "connected_nodes",
      os: "os"
    ]
end

defmodule Wardrik.AgentRuntime do
  @moduledoc """
  Resource use of a running agent. The numbers cover the agent's process, its current turn and
  its running tool calls.
  """

  use Wardrik.Type,
    schema: ["agent_runtime"],
    fields: [
      agent: "agent",
      conversation: "conversation",
      node: "node",
      memory_bytes: "memory_bytes",
      binary_bytes: "binary_bytes",
      processes: "processes",
      message_queue: "message_queue",
      reductions: "reductions"
    ]
end
