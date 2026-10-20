defmodule WardrikChannel.Installation do
  @moduledoc """
  A channel installed in one workspace, such as a Slack workspace your app
  was added to. Your `WardrikChannel.Installations` builds one for each
  workspace it keeps:

      %WardrikChannel.Installation{
        channel: "slack",
        workspace: "T0123",
        owner: Wardrik.Resource.parse!("acme"),
        token: "xoxb-…",
        approvers: %WardrikChannel.Approvers.Named{names: ["@maria"]}
      }

  Notice `approvers`. Each workspace says who decides there, so each org
  names its own.

    * `:channel` - the channel's name
    * `:workspace` - the workspace's id, as the medium gives it
    * `:owner` - whom it was installed for: an org, a user in one, or `*`,
      every org. Only the owner's agents answer there; see `covers?/2`.
    * `:token` - what the channel acts with there. `inspect/1` leaves it out.
    * `:approvers` - who decides what agents wait on there, as
      `WardrikChannel.Approvers`. Naming nobody, whoever asked for a turn
      decides it.
  """

  alias Wardrik.AgentAddress
  alias Wardrik.Resource

  @derive {Inspect, except: [:token]}
  @enforce_keys [:channel, :workspace, :owner, :token, :approvers]
  defstruct [:channel, :workspace, :owner, :token, :approvers]

  @type t() :: %__MODULE__{
          channel: String.t(),
          workspace: String.t(),
          owner: Wardrik.Resource.t(),
          token: String.t(),
          approvers: WardrikChannel.Approvers.t()
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
