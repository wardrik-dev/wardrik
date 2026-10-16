defmodule Wardrik.OrgGrants do
  @moduledoc "Grants everyone everything on the agents of `:org`."

  @enforce_keys [:org]
  defstruct [:org]

  defimpl Wardrik.Grants do
    def grants(%{org: org}, _principal) do
      {:ok, grant} = Wardrik.Grant.new(Wardrik.AgentID.Prefix.new!(org: org))
      [grant]
    end
  end
end
