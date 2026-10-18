defmodule WardrikTrigger.Source do
  @moduledoc """
  What a trigger watches: something it checks each time it comes due, which
  answers with what is new since it last looked, as `WardrikTrigger.Item`s.
  The trigger asks its agent only when there is something, with its prompt
  and the items under it.

  A trigger that names no source has the clock, `WardrikTrigger.Clock`,
  which answers with one item every time, so the agent is asked on every run.

  A source is named in a trigger by a key of its own, which a package
  registers (see `WardrikTrigger.Offered`), so a trigger written as

      %{"every" => "1h", "feed" => "https://example.com/feed.xml", "prompt" => "What is new?"}

  is read by `MyApp.Feed.decode/1` from every field but the ones every
  trigger has.

  ## The cursor

  `check/3` is handed what it answered last time as its cursor, `nil` the
  first time, and answers with the next. The trigger keeps it with the rest
  of its state, so it survives a restart and the node it ran on, and keeps it
  only once the agent is asked: items found while the agent was busy, or not
  there, are found again next time. A cursor is kept in the store, so it is
  small: the IDs of the items last seen, or a time, never the items.

  A check runs in the trigger's own process. One that fails as it may, such
  as a server that does not answer, answers `{:error, reason}`, and the run
  comes to `:failed`; one that raises loses the run, and the trigger goes on
  to its next.
  """

  alias Wardrik.AgentID
  alias WardrikTrigger.Item

  @typedoc "What a source answered last, to answer from next time."
  @type cursor() :: term()

  @doc """
  What the source reads from a trigger's fields: every field but `every`,
  `prompt`, `overlap`, `missed` and `jitter`, its own key among them.
  """
  @callback decode(fields :: %{String.t() => term()}) :: {:ok, term()} | {:error, String.t()}

  @doc "Its options written as fields, as `decode/1` reads them back."
  @callback encode(opts :: term()) :: %{String.t() => term()}

  @doc """
  What is new for `:agent` since `cursor`, and the cursor to check from next
  time. `:settings` are what the host started the triggers with for this
  source, such as the options of its requests.
  """
  @callback check(opts :: term(), cursor() | nil, agent: AgentID.t(), settings: keyword()) ::
              {:ok, [Item.t()], cursor()} | {:error, String.t()}
end
