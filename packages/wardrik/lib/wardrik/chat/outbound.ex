defmodule Wardrik.Chat.Outbound do
  @moduledoc """
  A message for the adapter to post, in `thread` of `room`, or in the room itself if `thread` is
  `nil`. See `c:Wardrik.Chat.deliver/2`.

  `body` is one of:

    * `{:progress, [%Wardrik.Chat.Step{}]}` - what the agent has done so far in a run, oldest
      first, each time a step starts, changes or ends. Sent again while a step runs quietly, so
      its time can be shown. Show it in one message: deliver returns `{:ok, progress}` with the
      message's ID, and later posts of the run carry it in `:progress`.
    * `{:reply, text, answering}` - the agent's answer, and the IDs of the messages it answers.
    * `{:stopped, answering}` - a run stopped before answering those messages.
    * `{:waiting, [%Wardrik.Chat.Waiting{}]}` - calls the agent waits on a person for.
    * `{:failed, reason}` - why a run failed.
    * `{:said, text}` - a line about what happened, such as who decided a call.
    * `{:notice, %Wardrik.Notice{}}` - what an agent did while nobody watched. Posted in the room.
      Read its calls with `Wardrik.Chat.Waiting.from_notice/1`.

  `:progress` is the ID the adapter returned for the run's progress, or `nil` before it returned
  one. A reply, stop, wait or failure ends the run's progress, so the adapter can finish it.

  `:asker` is the chat app's ID for the member whose message started the run, if known.

  `:agent` and `:conversation` name the conversation a post in a thread is about, and `:run` the
  run, if any. Put them on a reply's feedback buttons, and pass them back in a
  `Wardrik.Chat.Rating` to `Wardrik.Chat.rate/2`.

  `:prompts` are questions the member might ask next, suggested by the run and in the order to
  show them. A chat app shows them with the reply. It's `[]` when the run suggested none. See
  `Wardrik.Chat.Prompts.suggest_next/2`.
  """

  @enforce_keys [:installation, :room, :thread, :body]
  defstruct @enforce_keys ++
              [progress: nil, asker: nil, agent: nil, conversation: nil, run: nil, prompts: []]

  @type body() ::
          {:progress, [Wardrik.Chat.Step.t()]}
          | {:reply, String.t(), [String.t()]}
          | {:stopped, [String.t()]}
          | {:waiting, [Wardrik.Chat.Waiting.t()]}
          | {:failed, String.t()}
          | {:said, String.t()}
          | {:notice, Wardrik.Notice.t()}

  @type t() :: %__MODULE__{
          installation: Wardrik.Channel.Installation.t(),
          room: String.t(),
          thread: String.t() | nil,
          body: body(),
          progress: String.t() | nil,
          asker: String.t() | nil,
          agent: String.t() | nil,
          conversation: String.t() | nil,
          run: String.t() | nil,
          prompts: [String.t()]
        }
end
