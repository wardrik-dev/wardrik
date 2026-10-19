defmodule Wardrik.DeploymentIssuer do
  @moduledoc """
  Issues the deployment `agent.events` on every agent, `*/agent/*`, as a
  host running `WardrikNotify` does, and anyone else nothing.
  """

  defstruct []

  defimpl Wardrik.Issuer do
    def issue(_issuer, principal, _opts),
      do: %Wardrik.Token{principal: principal, scope: scope(Wardrik.Principal.id(principal))}

    defp scope("deployment"),
      do: [
        %Wardrik.Statement{
          actions: ["agent.events"],
          resources: [Wardrik.Resource.parse!("*/agent/*")]
        }
      ]

    defp scope(_anyone_else), do: []
  end
end
