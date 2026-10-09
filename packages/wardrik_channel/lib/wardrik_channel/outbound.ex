defmodule WardrikChannel.Outbound do
  @moduledoc """
  What a channel is asked to post: where, and what.

    * `:room` - the room, as the channel names it, such as `"#ops"` or a
      Slack channel's id
    * `:thread` - the thread in the room to post in, or `nil` for the room
      itself
    * `:body` - `{:notice, notice}`, a `WardrikNotify.Notice`, or
      `{:reply, text, answering}`, what an agent answered in a thread, and
      the ids of the messages it answers
    * `:approvers` - who may answer what it asks, as the channel names
      people; anyone in the room where it names nobody
  """

  @enforce_keys [:room, :body]
  defstruct [:room, :thread, :body, approvers: []]

  @type body() :: {:notice, WardrikNotify.Notice.t()} | {:reply, String.t(), [String.t()]}

  @type t() :: %__MODULE__{
          room: String.t(),
          thread: String.t() | nil,
          body: body(),
          approvers: [String.t()]
        }
end
