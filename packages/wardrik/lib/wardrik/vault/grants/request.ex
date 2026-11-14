defmodule Wardrik.Vault.Grants.Request do
  @moduledoc """
  What a `Wardrik.Vault.Grants` callback is asked about.

      %Wardrik.Vault.Grants.Request{
        vault: MyApp.Vault,
        name: "github",
        principal: %Wardrik.Principal{id: "user_42"},
        grant: %{value: json, vsn: vsn}
      }

  `grant` is what the principal holds, for `c:Wardrik.Vault.Grants.renew/2`. `nil` otherwise.
  """

  alias Wardrik.Principal

  @enforce_keys [:vault, :name, :principal]
  defstruct [:vault, :name, :principal, :grant]

  @type t() :: %__MODULE__{
          vault: GenServer.name(),
          name: String.t(),
          principal: Principal.t(),
          grant: Wardrik.Vault.Grants.grant() | nil
        }
end
