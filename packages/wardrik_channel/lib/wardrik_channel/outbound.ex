defmodule WardrikChannel.Outbound do
  @moduledoc """
  What a channel is asked to post: where, and what.

    * `:installation` - the `WardrikChannel.Installation` of the workspace
      to post in, whose token it is posted with
    * `:room` - the room, as the channel names it, such as `"#ops"` or a
      Slack channel's id
    * `:thread` - the thread in the room to post in, or `nil` for the room
      itself
    * `:body` - `{:notice, notice}`, a `WardrikNotify.Notice`, or
      `{:reply, text, answering}`, what is said in a thread, such as what
      an agent answered, and the ids of the messages it answers, if any
    * `:approvers` - whom it asks, as the channel names people; who may
      answer is what the token the host's `Wardrik.Issuer` issues them
      allows
    * `:to` - `:room`, to post it in the room, or `:approvers`, to ask each
      of them directly what it asks, and say in the thread who it waits on;
      a channel that cannot reach a person directly posts it in the room
  """

  @enforce_keys [:installation, :room, :body]
  defstruct [:installation, :room, :thread, :body, approvers: [], to: :room]

  @type body() :: {:notice, WardrikNotify.Notice.t()} | {:reply, String.t(), [String.t()]}

  @type t() :: %__MODULE__{
          installation: WardrikChannel.Installation.t(),
          room: String.t(),
          thread: String.t() | nil,
          body: body(),
          approvers: [String.t()],
          to: :room | :approvers
        }
end
