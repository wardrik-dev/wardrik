defmodule WardrikChannel.Outbound do
  @moduledoc """
  What a channel is asked to post: where, and what.

    * `:room` - the room, as the channel names it, such as `"#ops"` or a
      Slack channel's id
    * `:body` - `{:notice, notice}`, a `WardrikNotify.Notice`
    * `:approvers` - who may answer what it asks, as the channel names
      people; anyone in the room where it names nobody
  """

  @enforce_keys [:room, :body]
  defstruct [:room, :body, approvers: []]

  @type body() :: {:notice, WardrikNotify.Notice.t()}

  @type t() :: %__MODULE__{room: String.t(), body: body(), approvers: [String.t()]}
end
