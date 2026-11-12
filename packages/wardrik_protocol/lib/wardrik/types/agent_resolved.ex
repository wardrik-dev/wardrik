defmodule Wardrik.AgentResolved do
  @moduledoc """
  What an agent gets from the app that runs it: who it works for, its policies, MCP servers,
  notify targets, channels and workspaces.
  """

  use Wardrik.Type,
    schema: ["agent_resolved"],
    fields: [
      agent: "agent",
      principal: "principal",
      servers: "servers",
      policy: "policy",
      policies: "policies",
      defaults: "defaults",
      notify: "notify",
      channels: "channels",
      workspaces: "workspaces"
    ]
end
