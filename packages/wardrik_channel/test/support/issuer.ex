defmodule WardrikChannel.Test.Issuer do
  @moduledoc """
  The issuer of a test's host: each principal it names, by id, may read and
  message every agent, and anyone else nothing.
  """
  defstruct reach: []

  defimpl Wardrik.Issuer do
    def issue(%{reach: reach}, principal, _opts) do
      scope =
        if Wardrik.Principal.id(principal) in reach,
          do: [Wardrik.Role.bind([:reader, :messenger], Wardrik.AgentID.Prefix.all())],
          else: []

      %Wardrik.Token{principal: principal, scope: scope}
    end
  end
end
