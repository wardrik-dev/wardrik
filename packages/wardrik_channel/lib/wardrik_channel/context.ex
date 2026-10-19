defmodule WardrikChannel.Context do
  @moduledoc """
  What a channel is handed by the host that runs it: its name, the host,
  where the host keeps the workspaces it is installed in, and what the host
  says of it. `WardrikChannel.channels/2` makes one for each channel from
  its settings, and `WardrikChannel.Workspace` reads the agents it offers
  from the host's `Wardrik.Definitions`.

    * `:channel` - the channel's name, as `config.yaml` gives it
    * `:host` - the `Wardrik.Host` the channel was started on, whose
      `Wardrik.Issuer` issues a person known by their principal the token
      they act with, through `Wardrik.as/3`, and whose definitions say
      which agents answer in its rooms
    * `:installations` - the host's `WardrikChannel.Installations`
    * `:orgs` - the orgs whose agents it offers, of those whose definitions
      name it, or `:all`, the default
    * `:org` - the org an agent created in its rooms is in where it offers
      every org's agents; where it offers some, the first of them
    * `:creates` - whether someone in a room may create an agent to answer
      there, from the `defaults` of its org's definitions, which must name
      a policy its calls are held to; yes by default
    * `:approvers` - who decides what an agent asks in its threads, as
      `WardrikChannel.Approvers`; nobody named by default. They are asked
      directly, and the room where it names nobody; who may answer is what
      the token the host's `Wardrik.Issuer` issues them allows
    * `:replies` - the name of the `WardrikChannel.Replies` that posts what
      agents answer in its threads; `WardrikChannel.Replies.supervisor/0`
      by default
  """

  @enforce_keys [:channel, :host, :installations]
  defstruct [
    :channel,
    :host,
    :installations,
    orgs: :all,
    org: "default",
    creates: true,
    approvers: %WardrikChannel.Approvers.Named{names: []},
    replies: WardrikChannel.Replies.Rooms
  ]

  @type t() :: %__MODULE__{
          channel: String.t(),
          host: Wardrik.Host.t(),
          installations: WardrikChannel.Installations.t(),
          orgs: :all | [String.t()],
          org: String.t(),
          creates: boolean(),
          approvers: WardrikChannel.Approvers.t(),
          replies: atom()
        }
end
