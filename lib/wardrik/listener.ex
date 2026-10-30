defmodule Wardrik.Listener do
  @moduledoc """
  Follows agents' events into your app.

  Each event comes with the cursor just past it. Save the cursor with your work, and the listener
  picks up from it after a restart.

      defmodule MyApp.Runs do
        use Wardrik.Listener, wardrik: MyApp.AgentRuntime, types: ["wardrik.run.completed"]

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

  Start it after Wardrik in your supervision tree, or have Wardrik start it:

      Wardrik.start_link(name: MyApp.AgentRuntime, listeners: [MyApp.Runs])

  ## Options

  Give options to `use`, or as it starts. Your own options are kept alongside them.

    * `:wardrik` - required. The module to follow, as `MyApp.AgentRuntime`.
    * `:resources` - patterns of the agents to follow. Every agent unless set.
    * `:types` - event types to follow. Every type unless set.
    * `:after` - the cursor to start after, if you don't define `c:cursor/1`.

  Without a cursor, it starts with events written after it starts.

  ## Delivery

  Each event is delivered at least once. Save the cursor in the same transaction as your work,
  and drop repeats by the event's `id`. If `c:handle/2` raises or returns anything but `:ok`, the
  listener restarts and calls `c:cursor/1` again.
  """

  alias Wardrik.Instance

  @enforce_keys [:wardrik, :cursor, :options]
  defstruct [:wardrik, :cursor, :options]

  @typedoc "The listener: the `:wardrik` it follows, the cursor past the current event, and its options."
  @type t() :: %__MODULE__{wardrik: atom(), cursor: String.t() | nil, options: keyword()}

  @doc "Handles `event`. Returns `:ok` when done."
  @callback handle(Wardrik.Event.t(), t()) :: :ok

  @doc "Returns the cursor to start after, or `nil` to start with new events. Defaults to `:after`."
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

  @doc "Starts `module` as a listener. See the module docs for `opts`."
  @spec start_link(module(), keyword()) :: {:ok, pid()}
  def start_link(module, opts) do
    instance = Keyword.fetch!(opts, :wardrik)
    events = instance |> Instance.fetch!() |> Wardrik.events()
    started = WardrikEvents.head(events, Keyword.get(opts, :resources, ["*"]))
    options = [events: events, listener: module, started: started] ++ opts
    WardrikEvents.Listener.start_link(Wardrik.Listener.Events, options)
  end
end

defmodule Wardrik.Listener.Events do
  @moduledoc false

  use WardrikEvents.Listener

  @impl WardrikEvents.Listener
  def handle(event, listener),
    do: module(listener).handle(Wardrik.Event.from_json(event), ours(listener))

  @impl WardrikEvents.Listener
  def cursor(listener), do: module(listener).cursor(ours(listener)) || listener.options[:started]

  defp module(listener), do: Keyword.fetch!(listener.options, :listener)

  defp ours(listener) do
    options = Keyword.drop(listener.options, [:events, :listener, :wardrik, :started])

    %Wardrik.Listener{
      wardrik: listener.options[:wardrik],
      cursor: listener.cursor,
      options: options
    }
  end
end
