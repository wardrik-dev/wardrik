defmodule WardrikChannel.Context do
  @moduledoc """
  What a channel is handed by the host that runs it: its name, where the
  host keeps the workspaces it is installed in, and the host's own answers
  to what a channel cannot know, each a `{module, function, args}` the
  arguments named below are appended to. Each answer is given the
  `WardrikChannel.Installation` of the workspace it is asked for, as
  `WardrikChannel.Workspace` asks it.

    * `:channel` - the channel's name, as `config.yaml` gives it
    * `:host` - the `Wardrik.Host` the channel was started on, whose
      `Wardrik.Issuer` issues a person known by their principal the token
      they act with, through `Wardrik.as/3`
    * `:installations` - the host's `WardrikChannel.Installations`
    * `:offered` - given the installation, the agents that may answer in
      its rooms, as `WardrikChannel.Offer`s; none by default
    * `:creatable` - given the installation, whether someone in a room may
      create an agent to answer there; no by default
    * `:create` - given the installation, the room's name and who asked,
      creates an agent offered there, answering `{:ok, offer}` or
      `{:error, message}`
    * `:start` - given the installation and the ID of one of its threads'
      agents, starts it where it is not running, answering `{:ok, pid}` or
      `{:error, message}`; none is started by default
    * `:approvers` - given the installation, who decides what an agent asks
      in its threads, as `WardrikChannel.Approvers`; nobody named by
      default. They are asked directly, and the room where it names nobody;
      who may answer is what the token the host's `Wardrik.Issuer` issues
      them allows
    * `:offering` - given the installation, how an agent comes to answer in
      its rooms, as said where none does: `Whoever runs Wardrik can offer
      an agent here.` by default
    * `:deciding` - given the installation, who else may decide what an
      agent asks, as said to someone refused: `Whoever runs Wardrik names
      who else may.` by default
    * `:replies` - the name of the `WardrikChannel.Replies` that posts what
      agents answer in its threads; `WardrikChannel.Replies.supervisor/0`
      by default
  """

  alias Wardrik.AgentID
  alias Wardrik.Principal
  alias WardrikChannel.Approvers
  alias WardrikChannel.Installation

  @enforce_keys [:channel, :host, :installations]
  defstruct [
    :channel,
    :host,
    :installations,
    offered: {__MODULE__, :none, []},
    creatable: {__MODULE__, :no, []},
    create: {__MODULE__, :refuse, []},
    start: {__MODULE__, :unstarted, []},
    approvers: {__MODULE__, :nobody, []},
    offering: {__MODULE__, :offered_by_whoever_runs_it, []},
    deciding: {__MODULE__, :named_by_whoever_runs_it, []},
    replies: WardrikChannel.Replies.Rooms
  ]

  @type host() :: {module(), atom(), [term()]}

  @type t() :: %__MODULE__{
          channel: String.t(),
          host: Wardrik.Host.t(),
          installations: WardrikChannel.Installations.t(),
          offered: host(),
          creatable: host(),
          create: host(),
          start: host(),
          approvers: host(),
          offering: host(),
          deciding: host(),
          replies: atom()
        }

  @doc false
  @spec none(Installation.t()) :: []
  def none(_installation), do: []

  @doc false
  @spec no(Installation.t()) :: false
  def no(_installation), do: false

  @doc false
  @spec refuse(Installation.t(), String.t(), Principal.t() | nil) :: {:error, String.t()}
  def refuse(_installation, _name, _by), do: {:error, "This channel creates no agents."}

  @doc false
  @spec unstarted(Installation.t(), AgentID.t()) :: {:error, String.t()}
  def unstarted(installation, agent),
    do: {:error, "#{Installation.shown(installation, agent)} is not running."}

  @doc false
  @spec nobody(Installation.t()) :: Approvers.Named.t()
  def nobody(_installation), do: %Approvers.Named{names: []}

  @doc false
  @spec offered_by_whoever_runs_it(Installation.t()) :: String.t()
  def offered_by_whoever_runs_it(_installation),
    do: "Whoever runs Wardrik can offer an agent here."

  @doc false
  @spec named_by_whoever_runs_it(Installation.t()) :: String.t()
  def named_by_whoever_runs_it(_installation), do: "Whoever runs Wardrik names who else may."
end
