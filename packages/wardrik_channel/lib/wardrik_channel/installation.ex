defmodule WardrikChannel.Installation do
  @moduledoc """
  A channel installed in one workspace: a Slack workspace the app was added
  to, say. It is owned by the agents' owner it was installed for, whose
  agents alone answer there (`covers?/2`), and holds the token the channel
  acts there with, which is left out of how it is inspected.

    * `:channel` - the channel's name
    * `:workspace` - the workspace's id, as the installation names it
    * `:owner` - whom it was installed for, as `Wardrik.Resource` names
      them: an org, a user in one, or `*`, every org, as a deployment
      installs a channel that offers several
    * `:token` - what the channel acts in the workspace with

  The host keeps installations; see `WardrikChannel.Installations`.

  An agent is written in the workspace by `shown/2`: its ID after the
  owner's, which every agent offered there shares, so a workspace installed
  for an org reads `triage`, not the org's id before it.
  """

  alias Wardrik.AgentAddress
  alias Wardrik.Resource

  @derive {Inspect, except: [:token]}
  @enforce_keys [:channel, :workspace, :owner, :token]
  defstruct [:channel, :workspace, :owner, :token]

  @type t() :: %__MODULE__{
          channel: String.t(),
          workspace: String.t(),
          owner: Wardrik.Resource.t(),
          token: String.t()
        }

  @doc """
  How `agent` reads in the installation's workspace: its ID after the
  owner's, as `triage` or `@jon/triage` where the owner is an org; whole
  where the owner is not its org.
  """
  @spec shown(t(), AgentAddress.t()) :: String.t()
  def shown(%__MODULE__{owner: owner}, agent),
    do: String.replace_prefix(to_string(agent), "#{owner}/", "")

  @doc """
  Whether `agent` is the owner's: an agent of the org it was installed
  for, its users' among them, or of the user, or a `Wardrik.Thread` of
  one; any agent, for `*`.
  """
  @spec covers?(t(), AgentAddress.t()) :: boolean()
  def covers?(%__MODULE__{owner: owner}, agent),
    do: Resource.covers?(Resource.parse!("#{owner}/*"), AgentAddress.resource(agent))
end
