defmodule Wardrik.OrgSettings do
  @moduledoc """
  An org's settings, as `c:Wardrik.Orgs.settings/2` returns them.

      %Wardrik.OrgSettings{
        policy: [deny: ["shell/*"]],
        policies: %{"careful" => [ask: ["github/*"]]},
        defaults: %{"model" => "anthropic:claude-haiku-4-5"},
        ceilings: %{"spending-cap" => [usd: 20.00, per: :day]}
      }

  ## Fields

    * `:policy` - the `WardrikPolicy` every agent in the org is held to, or its rules, or a list
      of them. Checked after the deployment's policy and before the agent's own.
    * `:policies` - named policies the org's definitions may use, alongside the deployment's.
      A name the deployment already uses is refused.
    * `:defaults` - what the org's definitions get where they say nothing. Overrides the
      deployment's `:defaults`.
    * `:ceilings` - named budgets the org's agents share. See `Wardrik.Ceiling`.
  """

  defstruct policy: nil, policies: %{}, defaults: %{}, ceilings: %{}

  @type t() :: %__MODULE__{
          policy: WardrikPolicy.t() | keyword() | map() | [WardrikPolicy.t() | map()] | nil,
          policies: %{optional(String.t()) => WardrikPolicy.t() | keyword() | map()},
          defaults: map(),
          ceilings: %{optional(String.t()) => keyword() | map()}
        }
end
