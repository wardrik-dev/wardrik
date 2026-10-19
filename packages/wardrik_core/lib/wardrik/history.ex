defprotocol Wardrik.History do
  @moduledoc """
  What an agent keeps of its history: a value that may rewrite the history
  before each turn begins.

  A turn's task hands the agent's history to its config's `:history` first,
  before the messages the turn answers join it, so those stay word for word.
  The agent keeps what it answers: the turn runs on it, a turn that parks or
  is lost keeps it, and `Wardrik.Event.ContextCompacted` reports what changed on
  the turn's trace. `Wardrik.Compaction`, the default, summarises the older
  part once the history outgrows what the model can read, and
  `Wardrik.History.All` keeps every message.

      Wardrik.LLM.Config.new(history: %MyApp.Retention{days: 30})

  A history is a struct this protocol is implemented for, so it travels with
  the agent as data.

  `prepare/3` answers the history to keep, `:keep` to keep it as it is, or
  `{:error, reason}`, which keeps it as it is too. One that raises fails the
  turn.

  It runs in the turn's task: a model call it makes is one of the turn's,
  decided and counted by its hooks (see `Wardrik.Call.Pipeline`), and
  interrupting the turn interrupts it. It runs before a fresh turn alone; a
  turn carried on from a checkpoint or a park runs on the history it had.
  """

  @typedoc "What a rewrite did, as `Wardrik.Event.ContextCompacted` reports it."
  @type stats() :: %{
          messages_before: non_neg_integer(),
          messages_after: non_neg_integer(),
          tokens_before: non_neg_integer(),
          tokens_after: non_neg_integer()
        }

  @doc """
  The conversation to keep in place of `conversation` before a turn under
  `:run`, `:keep` for it as it is, or `{:error, reason}`, which keeps it too.
  """
  @spec prepare(t(), Wardrik.Conversation.t(), run: Wardrik.Run.t()) ::
          {:ok, Wardrik.Conversation.t()} | :keep | {:error, term()}
  def prepare(history, conversation, opts)
end
