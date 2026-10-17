defmodule WardrikChannel.Installation do
  @moduledoc """
  A channel installed in one workspace: a Slack workspace the app was added
  to, say. It is owned by the agents' owner it was installed for, and holds
  the token the channel acts there with, which is left out of how it is
  inspected.

    * `:channel` - the channel's name
    * `:workspace` - the workspace's id, as the installation names it
    * `:owner` - the `Wardrik.AgentID.Prefix` it was installed for, such as
      an org's agents
    * `:token` - what the channel acts in the workspace with

  The host keeps installations; see `WardrikChannel.Installations`.
  """

  @derive {Inspect, except: [:token]}
  @enforce_keys [:channel, :workspace, :owner, :token]
  defstruct [:channel, :workspace, :owner, :token]

  @type t() :: %__MODULE__{
          channel: String.t(),
          workspace: String.t(),
          owner: Wardrik.AgentID.Prefix.t(),
          token: String.t()
        }
end
