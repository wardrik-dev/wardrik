defmodule WardrikChannel.Context do
  @moduledoc """
  What a channel is handed by the host that runs it: its name, where the
  host keeps the workspaces it is installed in, and the host's own answers
  to what a channel cannot know, each a `{module, function, args}` the
  arguments named below are appended to. Each answer is given the
  `WardrikChannel.Installation` of the workspace it is asked for, as
  `WardrikChannel.Workspace` asks it.

    * `:channel` - the channel's name, as `config.yaml` gives it
    * `:host` - the `Wardrik.Host` the channel was started on, which a
      person known by their principal is asked of with
      `Wardrik.Host.caller/2`
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
      who may answer is what the host's `Wardrik.Grants` says
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
  def unstarted(_installation, agent), do: {:error, "#{agent} is not running."}

  @doc false
  @spec nobody(Installation.t()) :: Approvers.Named.t()
  def nobody(_installation), do: %Approvers.Named{names: []}
end
