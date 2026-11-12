defmodule Wardrik.Listener do
  @moduledoc """
  Follows the events of the agents you name into your app.

      defmodule MyApp.Runs do
        use Wardrik.Listener,
          wardrik: MyApp.AgentRuntime,
          agents: ["agt_support"],
          types: ["wardrik.run.completed"]

        @impl true
        def handle(%Wardrik.Event{} = event, listener) do
          MyApp.Repo.transaction(fn ->
            MyApp.Repo.insert!(MyApp.Run.from(event), on_conflict: :nothing)
            MyApp.Cursors.put!("runs", listener.cursor)
          end)

          :ok
        end

        @impl true
        def cursor(_listener), do: MyApp.Cursors.get("runs")
      end

  Start it after Wardrik, or with Wardrik's `listeners: [MyApp.Runs]`.

    * Each event arrives at least once. Drop repeats by `id`.
    * Save the cursor with your work. `c:cursor/1` returns it after a restart.
    * Without a cursor, it starts with new events.
    * If `c:handle/2` raises or doesn't return `:ok`, it restarts from `c:cursor/1`.

  ## Options

  Give them to `use`, or as it starts. Others are kept in `listener.options`.

    * `:wardrik` - required. The module to follow, as `MyApp.AgentRuntime`.
    * `:agents` - required. Agent IDs to follow, with their conversations. To take every agent's
      events, give Wardrik a `Wardrik.Sink`.
    * `:types` - event types to follow. Every type unless set.
    * `:after` - the cursor to start after, without `c:cursor/1`.
  """

  alias Wardrik.EventLog.Cursor
  alias Wardrik.Instance

  @enforce_keys [:wardrik, :cursor, :options]
  defstruct [:wardrik, :cursor, :options]

  @typedoc "The listener: its `:wardrik`, the cursor past the current event, and its options."
  @type t() :: %__MODULE__{wardrik: atom(), cursor: String.t() | nil, options: keyword()}

  @doc "Handles `event`. Returns `:ok` when done."
  @callback handle(Wardrik.Event.t(), t()) :: :ok

  @doc "Returns the cursor to start after, or `nil` for new events. `:after` unless defined."
  @callback cursor(t()) :: String.t() | nil

  defmacro __using__(opts) do
    quote do
      @behaviour Wardrik.Listener

      @doc false
      def child_spec(opts) do
        %{
          id: __MODULE__,
          start:
            {Wardrik.Listener, :start_link, [__MODULE__, Keyword.merge(unquote(opts), opts)]},
          restart: :permanent
        }
      end

      @impl Wardrik.Listener
      def cursor(listener), do: listener.options[:after]

      defoverridable child_spec: 1, cursor: 1
    end
  end

  @doc "Starts `module` as a listener."
  @spec start_link(module(), keyword()) :: {:ok, pid()}
  def start_link(module, opts) do
    # Wardrik's own chat apps give the event log, and follow it without a running Wardrik.
    events =
      Keyword.get_lazy(opts, :events, fn ->
        opts[:wardrik] |> Instance.fetch!() |> Wardrik.events()
      end)

    agents = Keyword.fetch!(opts, :agents)
    # Taken before the task starts, so "new events" means from now.
    started = Wardrik.EventLog.head(events, agents)
    Task.start_link(fn -> listen(module, events, started, opts) end)
  end

  defp listen(module, events, started, opts) do
    listener = %__MODULE__{
      wardrik: Keyword.fetch!(opts, :wardrik),
      cursor: nil,
      options: Keyword.drop(opts, [:wardrik, :events])
    }

    {:ok, stream} =
      Wardrik.EventLog.stream(events, Keyword.fetch!(opts, :agents),
        after: module.cursor(listener) || started,
        types: Keyword.get(opts, :types, :all)
      )

    Enum.each(stream, fn {event, cursor} ->
      :ok =
        module.handle(Wardrik.Event.from_json(event), %{listener | cursor: Cursor.encode(cursor)})
    end)
  end
end
