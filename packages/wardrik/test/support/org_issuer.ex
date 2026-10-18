defmodule Wardrik.OrgIssuer do
  @moduledoc "Issues everyone `owner` on the agents of `:org`."

  @enforce_keys [:org]
  defstruct [:org]

  defimpl Wardrik.Issuer do
    def issue(%{org: org}, principal, _opts) do
      prefix = Wardrik.AgentID.Prefix.new!(org: org)
      %Wardrik.Token{principal: principal, scope: [Wardrik.Role.bind([:owner], prefix)]}
    end
  end
end
