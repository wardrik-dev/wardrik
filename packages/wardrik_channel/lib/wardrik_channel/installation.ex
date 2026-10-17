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

  An agent is written in the workspace by `shown/2`: its ID after the
  owner's prefix, which every agent offered there shares, so a workspace
  installed for an org reads `triage`, not the org's id before it.
  """

  alias Wardrik.AgentID
  alias Wardrik.AgentID.Prefix

  @derive {Inspect, except: [:token]}
  @enforce_keys [:channel, :workspace, :owner, :token]
  defstruct [:channel, :workspace, :owner, :token]

  @type t() :: %__MODULE__{
          channel: String.t(),
          workspace: String.t(),
          owner: Wardrik.AgentID.Prefix.t(),
          token: String.t()
        }

  @doc """
  How `agent` reads in the installation's workspace: its ID after the
  owner's prefix, as `triage` or `@jon/triage` where the owner is an org;
  whole where it is not under the owner's prefix.
  """
  @spec shown(t(), AgentID.t()) :: String.t()
  def shown(%__MODULE__{owner: %Prefix{segments: own}}, %AgentID{} = agent) do
    segments = AgentID.segments(agent)

    if own != [] and List.starts_with?(segments, own) and length(segments) > length(own),
      do: segments |> Enum.drop(length(own)) |> Enum.join("/"),
      else: to_string(agent)
  end
end
