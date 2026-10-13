defmodule WardrikChannel.Context do
  @moduledoc """
  What a channel is handed by the host that runs it, and hands back to
  `WardrikChannel.Rooms` as it acts: its name, and the host's own answers to
  what a channel cannot know, each a `{module, function, args}` the
  arguments named below are appended to.

    * `:channel` - the channel's name, as `config.yaml` gives it
    * `:host` - the `Wardrik.Host` the channel was started on, which a
      person known by their principal is asked of with
      `Wardrik.Host.caller/2`
    * `:offered` - given the channel, the agents that may answer in its
      rooms, as `WardrikChannel.Offer`s; none by default
    * `:creatable` - given the channel, whether someone in a room may create
      an agent to answer there; no by default
    * `:create` - given the channel, the room's name and who asked, creates
      an agent offered in the channel, answering `{:ok, offer}` or
      `{:error, message}`
    * `:start` - given the channel and the ID of one of its threads' agents,
      starts it where it is not running, answering `{:ok, pid}` or
      `{:error, message}`; none is started by default
    * `:approvers` - given the channel, whom to ask what an agent asks in
      its threads, as the channel names people; the room by default. Who
      may answer is what the host's `Wardrik.Grants` says
    * `:replies` - the name of the `WardrikChannel.Replies` that posts what
      agents answer in its threads; `WardrikChannel.Replies.supervisor/0`
      by default
  """

  alias Wardrik.AgentID
  alias Wardrik.Principal
  alias WardrikChannel.Offer

  @enforce_keys [:channel, :host]
  defstruct [
    :channel,
    :host,
    offered: {__MODULE__, :none, []},
    creatable: {__MODULE__, :no, []},
    create: {__MODULE__, :refuse, []},
    start: {__MODULE__, :unstarted, []},
    approvers: {__MODULE__, :none, []},
    replies: WardrikChannel.Replies.Rooms
  ]

  @type host() :: {module(), atom(), [term()]}

  @type t() :: %__MODULE__{
          channel: String.t(),
          host: Wardrik.Host.t(),
          offered: host(),
          creatable: host(),
          create: host(),
          start: host(),
          approvers: host(),
          replies: atom()
        }

  @doc "The agents that may answer in a room of the context's channel."
  @spec offered(t()) :: [Offer.t()]
  def offered(%__MODULE__{channel: channel, offered: host}), do: call(host, [channel])

  @doc "Whether someone in a room may create an agent to answer there."
  @spec creatable?(t()) :: boolean()
  def creatable?(%__MODULE__{channel: channel, creatable: host}), do: call(host, [channel])

  @doc "Creates an agent for the room `name`, as `by` asked."
  @spec create(t(), String.t(), Principal.t() | nil) :: {:ok, Offer.t()} | {:error, String.t()}
  def create(%__MODULE__{channel: channel, create: host}, name, by),
    do: call(host, [channel, name, by])

  @doc "Starts `agent`, which answers in a thread of the channel's, where it is not running."
  @spec start(t(), AgentID.t()) :: {:ok, pid()} | {:error, String.t()}
  def start(%__MODULE__{channel: channel, start: host}, %AgentID{} = agent),
    do: call(host, [channel, agent])

  @doc "Who may answer what an agent asks in the channel's threads."
  @spec approvers(t()) :: [String.t()]
  def approvers(%__MODULE__{channel: channel, approvers: host}), do: call(host, [channel])

  defp call({module, function, args}, more), do: apply(module, function, args ++ more)

  @doc false
  @spec none(String.t()) :: []
  def none(_channel), do: []

  @doc false
  @spec no(String.t()) :: false
  def no(_channel), do: false

  @doc false
  @spec refuse(String.t(), String.t(), Principal.t() | nil) :: {:error, String.t()}
  def refuse(_channel, _name, _by), do: {:error, "This channel creates no agents."}

  @doc false
  @spec unstarted(String.t(), AgentID.t()) :: {:error, String.t()}
  def unstarted(_channel, agent), do: {:error, "#{agent} is not running."}
end
