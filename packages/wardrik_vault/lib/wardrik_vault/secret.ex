defmodule WardrikVault.Secret do
  @moduledoc """
  A value to seal, and who holds it under what name. See `WardrikVault.put/3`.

      WardrikVault.put(MyApp.Vault, %WardrikVault.Secret{
        principal: %WardrikCore.Principal{id: "user:jon"},
        name: "github",
        value: "ghp_..."
      })

  Inspecting it leaves out the value.
  """

  @derive {Inspect, except: [:value]}
  @enforce_keys [:principal, :name, :value]
  defstruct [:principal, :name, :value]

  @type t() :: %__MODULE__{
          principal: WardrikCore.Principal.t(),
          name: String.t(),
          value: binary()
        }
end
