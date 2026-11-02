defmodule WardrikVault.Grants.Request do
  @moduledoc """
  What a `WardrikVault.Grants` module is asked about: the grant `name`, for `principal`, in the
  vault `vault`.

      %WardrikVault.Grants.Request{
        vault: MyApp.Vault,
        name: "github",
        principal: %WardrikCore.Principal{id: "user_42"},
        grant: %{value: json, vsn: vsn}
      }

  `grant` is the grant the principal holds, given to `c:WardrikVault.Grants.renew/2`, and `nil`
  otherwise.
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
