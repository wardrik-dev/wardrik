defmodule WardrikChannel.Context do
  @moduledoc """
  What a channel is handed by the host that runs it, and hands back to
  `WardrikChannel.Rooms` as it acts: its name, and the host's own answers to
  what a channel cannot know, each a `{module, function, args}` the
  arguments named below are appended to.

    * `:channel` - the channel's name, as `config.yaml` gives it
    * `:offered` - given the channel, the agents that may answer in its
      rooms, as `WardrikChannel.Offer`s; none by default
    * `:creatable` - given the channel, whether someone in a room may create
      an agent to answer there; no by default
    * `:create` - given the channel, the room's name and who asked, creates
      an agent offered in the channel, answering `{:ok, offer}` or
      `{:error, message}`
  """

  alias Wardrik.Principal
  alias WardrikChannel.Offer

  @enforce_keys [:channel]
  defstruct [
    :channel,
    offered: {__MODULE__, :none, []},
    creatable: {__MODULE__, :no, []},
    create: {__MODULE__, :refuse, []}
  ]

  @type host() :: {module(), atom(), [term()]}

  @type t() :: %__MODULE__{
          channel: String.t(),
          offered: host(),
          creatable: host(),
          create: host()
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
end
