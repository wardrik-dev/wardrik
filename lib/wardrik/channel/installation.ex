defmodule Wardrik.Channel.Installation do
  @moduledoc """
  A channel added to one workspace, such as a Slack app added to one Slack workspace.

      %Wardrik.Channel.Installation{
        channel: "slack",
        workspace: "T0123",
        name: "Acme",
        owner: "acme",
        token: "xoxb-..."
      }

  ## Fields

    * `:channel` - the channel's name, as `"slack"`.
    * `:workspace` - the workspace's ID in the chat app.
    * `:owner` - who added it, as your app names them.
    * `:token` - the chat app's token for the workspace. Hidden from `inspect/2`.
    * `:name` - the workspace's name in the chat app, if it gave one.
  """

  @derive {Inspect, except: [:token]}
  @enforce_keys [:channel, :workspace, :owner, :token]
  defstruct [:channel, :workspace, :owner, :token, :name]

  @type t() :: %__MODULE__{
          channel: String.t(),
          workspace: String.t(),
          owner: String.t(),
          token: String.t(),
          name: String.t() | nil
        }
end
