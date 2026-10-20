defmodule WardrikChannel.Test.Issuer do
  @moduledoc """
  The issuer of a test's host: each principal it names, by id, may read and
  message every agent, the deployment may read every agent's events, as a
  host whose rooms post replies allows it, and anyone else nothing.
  """
  defstruct reach: []

  defimpl Wardrik.Issuer do
    def issue(%{reach: reach}, principal, _opts),
      do: %Wardrik.Token{
        principal: principal,
        scope: scope(reach, Wardrik.Principal.id(principal))
      }

    defp scope(_reach, "deployment"),
      do: [
        %Wardrik.Statement{
          actions: ["agent.events"],
          resources: [Wardrik.Resource.parse!("*/agent/*")]
        }
      ]

    defp scope(reach, id) do
      if id in reach,
        do: [Wardrik.Role.bind([:reader, :messenger], [Wardrik.Resource.parse!("*")])],
        else: []
    end
  end
end
