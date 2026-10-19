defprotocol Wardrik.Turn do
  @moduledoc """
  One turn of an agent, as a value: what `Wardrik.Agent` runs in a task,
  holds while it waits on a person, and writes down to carry on elsewhere.
  `Wardrik.LLM.Turn` is one.

  `run/1`, `resume/2` and `recover/1` run in the turn's task, under the
  `Wardrik.Run` `under/2` gave it, and each hands the turn back done,
  waiting or failed, as `status/1` says. The rest read the turn alone, so a
  turn written down, under no run, answers them as a live one does.

  A turn reads `Wardrik.Turn.Signal`'s messages from its mailbox: asked to
  yield, it ends at its next boundary, and asked to stop, as soon as it can.
  """

  @typedoc "What a person decided about each call a turn waits on, by call id."
  @type decisions() :: %{String.t() => Wardrik.Call.Pipeline.decision()}

  @typedoc """
  How a turn handed back came out: done, with the messages it added and the
  labels of what it read; waiting on a person; or failed, and why.
  """
  @type status() ::
          {:done, [Wardrik.Conversation.message()], [Wardrik.Label.t()]}
          | :waiting
          | {:failed, term()}

  @doc "Runs the turn until it is done, waits on a person, or fails."
  @spec run(t()) :: t()
  def run(turn)

  @doc "Carries on a waiting turn with the decisions a person made about its calls."
  @spec resume(t(), decisions()) :: t()
  def resume(turn, decisions)

  @doc """
  Carries on a turn lost part way, from the checkpoint it last handed its
  run's journal.
  """
  @spec recover(t()) :: t()
  def recover(turn)

  @doc "How the turn came out."
  @spec status(t()) :: status()
  def status(turn)

  @doc "The calls a waiting turn waits on, each with the prompt a person is shown."
  @spec waiting(t()) :: [{Wardrik.Tool.call(), String.t()}]
  def waiting(turn)

  @doc """
  The ids of the calls the turn waits on that were parked to resolve `ref`
  for `owner`; see `Wardrik.Credential.available/3`.
  """
  @spec awaiting(t(), Wardrik.Credential.ref(), Wardrik.Credential.owner()) :: [String.t()]
  def awaiting(turn, ref, owner)

  @doc "The turn under `run`, or under none for one that is written down."
  @spec under(t(), Wardrik.Run.t() | nil) :: t()
  def under(turn, run)

  @doc "Whether the turn waits under hooks other than `hooks`."
  @spec stale?(t(), [Wardrik.Hook.t()]) :: boolean()
  def stale?(turn, hooks)

  @doc """
  The turn as it is written down beside the history it began on, which
  `load/2` reads it back on.
  """
  @spec dump(t()) :: t()
  def dump(turn)

  @doc "Reads back a turn `dump/1` wrote, on `history`, the conversation it began on."
  @spec load(t(), Wardrik.Conversation.t()) :: t()
  def load(turn, history)
end
