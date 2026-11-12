defmodule WardrikVault.Grants.Request do
  @moduledoc """
  What a `WardrikVault.Grants` callback is asked about.

      %WardrikVault.Grants.Request{
        vault: MyApp.Vault,
        name: "github",
        principal: %WardrikCore.Principal{id: "user_42"},
        grant: %{value: json, vsn: vsn}
      }

  `grant` is what the principal holds, for `c:WardrikVault.Grants.renew/2`. `nil` otherwise.
  """

  alias WardrikCore.Principal

  @enforce_keys [:vault, :name, :principal]
  defstruct [:vault, :name, :principal, :grant]

  @type t() :: %__MODULE__{
          vault: GenServer.name(),
          name: String.t(),
          principal: Principal.t(),
          grant: WardrikVault.Grants.grant() | nil
        }
end
