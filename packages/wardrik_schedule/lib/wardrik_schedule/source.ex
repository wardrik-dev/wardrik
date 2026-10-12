defmodule WardrikSchedule.Source do
  @moduledoc """
  What a schedule watches: something it checks each time it comes due, which
  answers with what is new since it last looked, as `WardrikSchedule.Item`s.
  The schedule asks its agent only when there is something, with its prompt
  and the items under it.

  A schedule that names no source has the clock, `WardrikSchedule.Clock`,
  which answers with one item every time, so the agent is asked on every run.

  A source is named in a schedule by a key of its own, which a package
  registers in its application's environment:

      def application,
        do: [env: [wardrik_schedule_sources: [feed: MyApp.Feed]]]

  so a schedule written as

      %{"every" => "1h", "feed" => "https://example.com/feed.xml", "prompt" => "What is new?"}

  is read by `MyApp.Feed.decode/1` from every field but the ones every
  schedule has.

  ## The cursor

  `check/3` is handed what it answered last time as its cursor, `nil` the
  first time, and answers with the next. The schedule keeps it with the rest
  of its state, so it survives a restart and the node it ran on, and keeps it
  only once the agent is asked: items found while the agent was busy, or not
  there, are found again next time. A cursor is kept in the store, so it is
  small: the IDs of the items last seen, or a time, never the items.

  A check runs in the schedule's own process. One that fails as it may, such
  as a server that does not answer, answers `{:error, reason}`, and the run
  comes to `:failed`; one that raises loses the run, and the schedule goes on
  to its next.
  """

  alias Wardrik.AgentID
  alias WardrikSchedule.Item

  @typedoc "What a source answered last, to answer from next time."
  @type cursor() :: term()

  @doc """
  What the source reads from a schedule's fields: every field but `every`,
  `prompt`, `overlap`, `missed` and `jitter`, its own key among them.
  """
  @callback decode(fields :: %{String.t() => term()}) :: {:ok, term()} | {:error, String.t()}

  @doc "Its options written as fields, as `decode/1` reads them back."
  @callback encode(opts :: term()) :: %{String.t() => term()}

  @doc "What is new for `agent` since `cursor`, and the cursor to check from next time."
  @callback check(opts :: term(), cursor() | nil, AgentID.t()) ::
              {:ok, [Item.t()], cursor()} | {:error, String.t()}

  @doc "Every source the loaded applications name, by its key."
  @spec all() :: %{String.t() => module()}
  def all do
    for {app, _description, _version} <- Application.loaded_applications(),
        {key, module} <- Application.get_env(app, :wardrik_schedule_sources, []),
        into: %{},
        do: {to_string(key), module}
  end
end
