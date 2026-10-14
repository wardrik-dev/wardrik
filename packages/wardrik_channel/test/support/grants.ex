defmodule WardrikChannel.Test.Grants do
  @moduledoc """
  The grants of a test's host: each principal it names, by id, may read and
  message every agent, and anyone else nothing.
  """
  defstruct reach: []

  defimpl Wardrik.Grants do
    def grants(%{reach: reach}, principal) do
      if Wardrik.Principal.id(principal) in reach do
        {:ok, grant} = Wardrik.Grant.new(Wardrik.AgentID.Prefix.all(), [:read, :message])
        [grant]
      else
        []
      end
    end
  end
end
