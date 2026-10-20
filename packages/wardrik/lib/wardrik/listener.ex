defmodule Wardrik.Listener do
  @moduledoc """
  A process that follows agents' events and hands each to a module of the
  host's own, with the cursor past it, so the host keeps its place where it
  keeps its own work and carries on from there after any restart.

      defmodule MyApp.Runs do
        use Wardrik.Listener

        @impl true
        def handle(%Wardrik.Event.RunCompleted{id: id, source: agent} = event, listener) do
          MyApp.Repo.transaction(fn ->
            run = %MyApp.Run{event_id: id, agent: to_string(agent), messages: event.messages}
            MyApp.Repo.insert!(run, on_conflict: :nothing)
            MyApp.Cursors.put!("runs", listener.cursor)
          end)

          :ok
        end

        def handle(_event, listener) do
          MyApp.Cursors.put!("runs", listener.cursor)
          :ok
        end

        @impl true
        def cursor(listener), do: MyApp.Cursors.get("runs", listener.cursor)
      end

      children = [
        MyApp.Agents,
        {MyApp.Runs, agents: MyApp.Agents, types: ["wardrik.run.completed", "wardrik.run.failed"]}
      ]

  `use Wardrik.Listener` makes the module a child: `child_spec/1` and
  `start_link/1` take the options below, and the module's own beside them,
  which `handle/2` reads in `options`. It runs as a permanent `Task` under
  whatever supervisor the host starts it in.

  As it starts, it acts as your app on the agents of `:agents`, your `use
  Wardrik` instance, or as `:principal` on `:host`, in the scope
  `Wardrik.as/3` makes, so each start, a restart's included, has a token of
  its own. It asks `c:cursor/1` where to read from, by default the
  `:after` it was started with, and follows `Wardrik.events/2` from there.
  A cursor of `:head` is taken as `Wardrik.events_head/2`'s, so the
  cursor handed on names every log it reads.

  ## At least once

  Each event is handed to `c:handle/2` with the cursor past it in
  `cursor`. Where the host saves that cursor with what `handle/2` did,
  in one transaction, and `c:cursor/1` reads it back, each event is
  handled at least once: one whose `handle/2` was cut short is handed
  again after a restart. Drop a repeat by the event's `id`.

  A `handle/2` that raises, or answers anything but `:ok`, restarts the
  process, which asks `c:cursor/1` again; one that always raises restarts
  it until its supervisor gives up. Where a log was trimmed past the
  cursor, `handle/2` takes a `Wardrik.Event.EventsDropped`, whatever
  `:types` says.

  A listener runs where it is started: a host that starts it on every
  node of a cluster hands each event to each. One that is to run once in
  the cluster is started by a process that runs once, as
  `WardrikNotify.Keeper` starts its own.

  ## Options

    * `:agents` - your `use Wardrik` instance, whose agents it follows as
      your app. Or name `:host` and `:principal` instead.
    * `:host` - the `Wardrik.Host` the agents run on, where `:agents` is
      not given.
    * `:principal` - the `Wardrik.Principal` it acts as, which the host's
      `Wardrik.Issuer` allows `agent.events` on what it reads; your app
      itself, `Wardrik.Principal.deployment/0`, with `:agents`.
    * `:after` - the cursor `c:cursor/1` answers by default; `:head`, from
      what is written next, unless given.
    * `:resources` - the agents it follows, as `Wardrik.events/2` takes
      them; every agent the principal reads unless given.
    * `:types` - the CloudEvent types it takes, as `Wardrik.events/2` takes
      them; every type unless given.
  """

  @enforce_keys [:scope, :cursor, :options]
  defstruct [:scope, :cursor, :options]

  @typedoc """
  A listener as `handle/2` is handed it: the scope it reads in, the cursor
  past the event being handled, and the options it was started with.
  """
  @type t() :: %__MODULE__{
          scope: Wardrik.Scope.t(),
          cursor: String.t() | :head,
          options: keyword()
        }

  @doc """
  Does what the host does with `event`, with `listener.cursor` past it,
  answering `:ok` once it is done.
  """
  @callback handle(Wardrik.Event.t(), t()) :: :ok

  @doc """
  The cursor to read after as the listener starts: where the host saved
  its place, or `listener.cursor`, the `:after` it was started with.
  """
  @callback cursor(t()) :: String.t() | :head

  defmacro __using__(_opts) do
    quote do
      @behaviour Wardrik.Listener

      @doc "The child that runs this listener with `opts`; see `Wardrik.Listener`."
      @spec child_spec(keyword()) :: Supervisor.child_spec()
      def child_spec(opts), do: Wardrik.Listener.child_spec(__MODULE__, opts)

      @doc "Starts this listener with `opts`; see `Wardrik.Listener`."
      @spec start_link(keyword()) :: {:ok, pid()}
      def start_link(opts), do: Wardrik.Listener.start_link(__MODULE__, opts)

      @doc false
      def cursor(%Wardrik.Listener{cursor: cursor}), do: cursor

      defoverridable child_spec: 1, cursor: 1
    end
  end

  @doc "The child that runs `module`'s listener with `opts`, a permanent `Task`."
  @spec child_spec(module(), keyword()) :: Supervisor.child_spec()
  def child_spec(module, opts),
    do: %{id: module, start: {__MODULE__, :start_link, [module, opts]}, restart: :permanent}

  @doc """
  Starts `module`'s listener with `opts`, linked to the caller. Raises
  where neither `:agents` nor `:host` and `:principal` are given.
  """
  @spec start_link(module(), keyword()) :: {:ok, pid()}
  def start_link(module, opts) when is_atom(module) and is_list(opts) do
    {host, principal} = acting(opts)
    Task.start_link(fn -> listen(module, host, principal, opts) end)
  end

  defp acting(opts) do
    case Keyword.fetch(opts, :agents) do
      {:ok, instance} ->
        {Wardrik.Instance.host(instance),
         Keyword.get(opts, :principal, Wardrik.Principal.deployment())}

      :error ->
        {%Wardrik.Host{} = Keyword.fetch!(opts, :host), Keyword.fetch!(opts, :principal)}
    end
  end

  defp listen(module, host, principal, opts) do
    scope = Wardrik.as(host, principal)
    following = Keyword.take(opts, [:resources, :types])
    listener = %__MODULE__{scope: scope, cursor: Keyword.get(opts, :after, :head), options: opts}
    start = start(scope, module.cursor(listener), following)

    scope
    |> Wardrik.events!([after: start, follow: true] ++ following)
    |> Enum.each(fn event -> :ok = module.handle(event, %{listener | cursor: event.cursor}) end)
  end

  defp start(scope, :head, following),
    do: Wardrik.events_head!(scope, Keyword.take(following, [:resources]))

  defp start(_scope, cursor, _following), do: cursor
end
