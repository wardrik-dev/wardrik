defmodule WardrikChannel.Context do
  @moduledoc """
  What a channel is handed by the host that runs it, and hands back to
  `WardrikChannel.Rooms` as it acts: its name, and the host's own answers to
  what a channel cannot know.

    * `:channel` - the channel's name, as `config.yaml` gives it
    * `:offered` - which agents may answer in a room of the channel, as a
      `{module, function, args}` the channel's name is appended to,
      answering a list of `Wardrik.AgentID`s
  """

  @enforce_keys [:channel]
  defstruct [:channel, offered: {__MODULE__, :none, []}]

  @type t() :: %__MODULE__{channel: String.t(), offered: {module(), atom(), [term()]}}

  @doc "The agents that may answer in a room of the context's channel."
  @spec offered(t()) :: [Wardrik.AgentID.t()]
  def offered(%__MODULE__{channel: channel, offered: {module, function, args}}),
    do: apply(module, function, args ++ [channel])

  @doc false
  @spec none(String.t()) :: []
  def none(_channel), do: []
end
