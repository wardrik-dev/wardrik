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
    * `:approvers` - the approvers of a workspace installed with
      `WardrikChannel.install/3`; nobody named by default
    * `:offering` - what a room no agent answers in says
    * `:deciding` - what someone who may not decide a call is told
    * `:replies` - the name of the `WardrikChannel.Replies` that posts what
      agents answer in its threads; `WardrikChannel.Replies.supervisor/0`
      by default
  """

  @enforce_keys [:channel, :host, :installations, :offering, :deciding]
  defstruct [
    :channel,
    :host,
    :installations,
    :offering,
    :deciding,
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
          offering: String.t(),
          deciding: String.t(),
          replies: atom()
        }

  @doc "Whether the channel offers the agents of `agent`'s org, as its `:orgs` say."
  @spec offers?(t(), Wardrik.AgentID.t()) :: boolean()
  def offers?(%__MODULE__{orgs: orgs}, %Wardrik.AgentID{org: org}),
    do: orgs == :all or org in orgs
end
