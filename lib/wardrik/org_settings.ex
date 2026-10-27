defmodule Wardrik.OrgSettings do
  @moduledoc """
  What an org's agents are given and held to, as a `Wardrik.Orgs` answers for it.

    * `policy` - the `WardrikPolicy` every agent of the org is held to, after the deployment's and
      before its own, or the rules to build it from, or a list of them, held to in turn.
    * `policies` - the policies the org's definitions may name, by name, beside the deployment's.
      A name the deployment's policies have already is refused.
    * `defaults` - what the org's definitions are given where they say nothing, over the
      deployment's `:defaults`.
    * `ceilings` - budgets every agent of the org spends from together, by name, as
      `Wardrik.Ceiling` describes.
  """

  defstruct policy: nil, policies: %{}, defaults: %{}, ceilings: %{}

  @type t() :: %__MODULE__{
          policy: WardrikPolicy.t() | keyword() | map() | [WardrikPolicy.t() | map()] | nil,
          policies: %{optional(String.t()) => WardrikPolicy.t() | keyword() | map()},
          defaults: map(),
          ceilings: %{optional(String.t()) => keyword() | map()}
        }
end
