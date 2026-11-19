defmodule Wardrik.Chat.Direct.Request do
  @moduledoc """
  The member `c:Wardrik.Chat.Direct.agent/2` finds an agent for.

      %Wardrik.Chat.Direct.Request{
        channel: "slack",
        workspace: "T0123",
        principal: %Wardrik.Principal{id: "acme/@maria"}
      }

    * `:channel` - the channel's name.
    * `:workspace` - the workspace's ID in the chat app.
    * `:principal` - who the member is, as `Wardrik.Chat.Identities` said.
  """

  @enforce_keys [:channel, :workspace, :principal]
  defstruct [:channel, :workspace, :principal]

  @type t() :: %__MODULE__{
          channel: String.t(),
          workspace: String.t(),
          principal: Wardrik.Principal.t()
        }
end
