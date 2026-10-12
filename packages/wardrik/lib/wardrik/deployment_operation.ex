defmodule Wardrik.DeploymentOperation do
  @moduledoc """
  An operation on the deployment itself, as where its agents run: a caller
  takes it only where their grant reaches every agent and allows `action/0`;
  see `Wardrik.Deployment`.

  A module implements this beside one of `Wardrik.Query` or
  `Wardrik.Command`, as `Wardrik.AgentOperation` is for one agent and
  `Wardrik.FleetOperation` for the agents under a prefix.
  """

  @doc "The deployment `request` acts on."
  @callback subject(request :: struct()) :: Wardrik.Deployment.t()

  @doc "What a grant over every agent must allow for its holder to take it."
  @callback action() :: Wardrik.Grant.action()
end
