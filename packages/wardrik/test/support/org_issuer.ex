defmodule Wardrik.OrgIssuer do
  @moduledoc "Issues everyone `owner` on everything of `:org`'s, `org/*`."

  @enforce_keys [:org]
  defstruct [:org]

  defimpl Wardrik.Issuer do
    def issue(%{org: org}, principal, _opts) do
      tenant = Wardrik.Resource.parse!("#{org}/*")
      %Wardrik.Token{principal: principal, scope: [Wardrik.Role.bind([:owner], [tenant])]}
    end
  end
end
