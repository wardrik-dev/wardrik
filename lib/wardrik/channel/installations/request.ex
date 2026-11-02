defmodule Wardrik.Channel.Installations.Request do
  @moduledoc """
  Which installations a `Wardrik.Channel.Installations` callback acts on: the one in `workspace`,
  or those `owner` added.

      %Wardrik.Channel.Installations.Request{channel: "slack", workspace: "T0123"}
      %Wardrik.Channel.Installations.Request{channel: "slack", owner: "acme"}
  """

  @enforce_keys [:channel]
  defstruct [:channel, :workspace, :owner]

  @type t() :: %__MODULE__{
          channel: String.t(),
          workspace: String.t() | nil,
          owner: String.t() | nil
        }
end
