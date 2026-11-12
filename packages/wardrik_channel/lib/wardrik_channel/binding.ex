defmodule WardrikChannel.Binding do
  @moduledoc """
  The agent that answers in a room, and when.

  `answers` is `:mentions`, to answer only when mentioned, or `:everything`, to answer every
  message. `:mentions` unless set.
  """

  @enforce_keys [:room, :agent]
  defstruct [:room, :agent, answers: :mentions]

  @type answers() :: :mentions | :everything

  @type t() :: %__MODULE__{room: String.t(), agent: String.t(), answers: answers()}
end
