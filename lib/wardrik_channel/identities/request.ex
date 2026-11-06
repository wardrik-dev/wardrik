defmodule WardrikChannel.Identities.Request do
  @moduledoc """
  The member `c:WardrikChannel.Identities.identify/2` names.

      %WardrikChannel.Identities.Request{
        channel: "slack",
        workspace: "T0123",
        member: "U024BE7LH",
        name: "Maria",
        email: "maria@acme.com"
      }

    * `:channel` - the channel's name.
    * `:workspace` - the workspace's ID in the chat app.
    * `:member` - the member's ID in the chat app.
    * `:name` - the name the chat app shows, if it gave one.
    * `:email` - the member's email address in the chat app, if it gave one.
  """

  @enforce_keys [:channel, :workspace, :member]
  defstruct [:channel, :workspace, :member, :name, :email]

  @type t() :: %__MODULE__{
          channel: String.t(),
          workspace: String.t(),
          member: String.t(),
          name: String.t() | nil,
          email: String.t() | nil
        }
end
