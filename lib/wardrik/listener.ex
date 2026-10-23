defmodule Wardrik.Listener do
  @moduledoc """
  A listener follows agents' events into your app. It hands each event to your module with the
  cursor past it, so you keep your place with your own work, and carry on from it after a restart.

      defmodule MyApp.Runs do
        use Wardrik.Listener, wardrik: MyApp.Wardrik, types: ["wardrik.run.completed"]

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

  Start it after its Wardrik, or let the Wardrik start it, with `listeners: [MyApp.Runs]`. It takes
  `:wardrik`, `:resources` (every agent unless set), `:types` (every type unless set) and `:after`,
  the cursor `cursor/1` returns unless you define it, in `use` or as it starts, and your module's
  own options beside them. Without a cursor, it reads from what's written once it starts.

  Each event is handed over at least once: keep the cursor with what `handle/2` did, in one
  transaction, and drop a repeat by the event's `id`. A `handle/2` that raises or returns anything
  but `:ok` restarts the listener, which asks `cursor/1` again.
  """

  alias Wardrik.Instance

  @enforce_keys [:wardrik, :cursor, :options]
  defstruct [:wardrik, :cursor, :options]

  @typedoc "The Wardrik it follows, the cursor past the event being handled, and its options."
  @type t() :: %__MODULE__{wardrik: atom(), cursor: String.t() | nil, options: keyword()}

  @doc "Does what your app does with `event`, and returns `:ok` once it's done."
  @callback handle(Wardrik.Event.t(), t()) :: :ok

  @doc "Returns the cursor to read after as the listener starts, or `nil` for what's written next."
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

  @doc "Starts `module`'s listener, following the Wardrik its `:wardrik` names."
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
