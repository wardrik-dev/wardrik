defmodule WardrikChannel.Waiting do
  @moduledoc """
  A call the agent waits on a person to decide.

    * `:agent` - the agent's ID.
    * `:conversation` - the conversation it's in, or `nil` for the agent's own.
    * `:interrupt` - the `Wardrik.Interrupt`.
    * `:arguments` - the call's arguments, if known.
    * `:asked_by` - the ID of who asked for the turn, if known.

  Put `agent`, `conversation`, the interrupt's `id` and `asked_by` on the buttons. Pass them back
  in a `WardrikChannel.Answer` to `WardrikChannel.decide/2`.
  """

  @enforce_keys [:agent, :interrupt]
  defstruct [:agent, :conversation, :interrupt, :arguments, :asked_by]

  @type t() :: %__MODULE__{
          agent: String.t(),
          conversation: String.t() | nil,
          interrupt: Wardrik.Interrupt.t(),
          arguments: term(),
          asked_by: String.t() | nil
        }

  @doc "Returns the calls a parked turn's `notice` waits on, in the agent's own conversation."
  @spec from_notice(Wardrik.Notice.t()) :: [t()]
  def from_notice(%Wardrik.Notice{agent: agent, conversation: conversation, calls: calls}),
    do:
      for(
        %{interrupt: interrupt, arguments: arguments} <- calls,
        do: %__MODULE__{
          agent: agent,
          conversation: conversation,
          interrupt: interrupt,
          arguments: arguments
        }
      )
end
