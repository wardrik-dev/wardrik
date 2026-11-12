defmodule Wardrik.Chat.Outbound do
  @moduledoc """
  A message for the adapter to post, in `thread` of `room`, or in the room itself if `thread` is
  `nil`. See `c:Wardrik.Chat.deliver/2`.

  `body` is one of:

    * `{:reply, text, answering}` - the agent's answer, and the IDs of the messages it answers.
    * `{:status, label}` - what the agent is doing, in a few words. Shown until the next post.
    * `{:stopped, answering}` - a run stopped before answering those messages.
    * `{:waiting, [%Wardrik.Chat.Waiting{}]}` - calls the agent waits on a person for.
    * `{:failed, reason}` - why a run failed.
    * `{:said, text}` - a line about what happened, such as who decided a call.
    * `{:notice, %Wardrik.Notice{}}` - what an agent did while nobody watched. Posted in the room.
      Read its calls with `Wardrik.Chat.Waiting.from_notice/1`.
  """

  @enforce_keys [:installation, :room, :thread, :body]
  defstruct @enforce_keys

  @type body() ::
          {:reply, String.t(), [String.t()]}
          | {:status, String.t()}
          | {:stopped, [String.t()]}
          | {:waiting, [Wardrik.Chat.Waiting.t()]}
          | {:failed, String.t()}
          | {:said, String.t()}
          | {:notice, Wardrik.Notice.t()}

  @type t() :: %__MODULE__{
          installation: Wardrik.Channel.Installation.t(),
          room: String.t(),
          thread: String.t() | nil,
          body: body()
        }
end
