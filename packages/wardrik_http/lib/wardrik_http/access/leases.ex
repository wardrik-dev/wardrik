defmodule WardrikHTTP.Access.Leases do
  @moduledoc """
  The processes on this node holding a record, and the ending of them when it
  is revoked. See `WardrikHTTP.Access`.

  A holder registers itself in a partitioned `Registry`, so holding and
  letting go never wait on this process, and the registry lets go of a holder
  that exits. This process runs on every node, joined to the group
  `WardrikHTTP.Access` names, so a revocation reaches each. On one it refuses the
  record in `WardrikHTTP.Access.Cache`, sends each holder the exit signal
  `{:shutdown, :revoked}`, and kills one still holding after the grace.

  Every sweep it reads each record held on this node through consensus, off
  its own process and several at once, and keeps what it reads in the cache.
  It revokes on this node a record that is gone. At the first record that
  cannot be read it stops, and ends every holder on the node, as it does when
  a sweep fails. It then purges what has lapsed from the cache.
  """

  use GenServer

  require Logger

  alias WardrikHTTP.Access
  alias WardrikHTTP.Access.Cache

  @group "leases"
  @registry WardrikHTTP.Access.Holders
  @tasks WardrikHTTP.Access.Tasks
  @read_timeout 2_000
  @concurrency 16

  @enforce_keys [:grace, :every]
  defstruct [:grace, :every, sweep: nil, waiting: [], timer: nil]

  @type t() :: %__MODULE__{
          grace: pos_integer(),
          every: pos_integer(),
          sweep: reference() | nil,
          waiting: [GenServer.from()],
          timer: reference() | nil
        }

  @doc false
  def registry_spec do
    {Registry, keys: :duplicate, name: @registry, partitions: System.schedulers_online()}
  end

  @doc false
  def tasks, do: @tasks

  @doc """
  Starts the leases of this node, with `:grace` and `:sweep` in
  milliseconds, as `WardrikHTTP.Access` takes them.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Registers the calling process as a holder of `ref`, and answers the id
  `release/2` takes to let go of this hold alone.
  """
  @spec hold(Access.ref()) :: reference()
  def hold(ref) do
    id = make_ref()
    {:ok, _owner} = Registry.register(@registry, ref, id)
    id
  end

  @doc "Lets go of the calling process's hold `id` on `ref`, and never ends it for that hold."
  @spec release(Access.ref(), reference()) :: :ok
  def release(ref, id), do: Registry.unregister_match(@registry, ref, id)

  @doc "Revokes `ref` on every node: each refuses it, and ends its holders there."
  @spec revoked(Access.ref()) :: :ok
  def revoked(ref), do: Group.dispatch(Access, @group, {:revoked, ref})

  @doc "Sweeps this node now, and answers once the sweep has ended what it ends."
  @spec sweep() :: :ok
  def sweep, do: GenServer.call(__MODULE__, :sweep, :infinity)

  @impl true
  def init(opts) do
    every = Keyword.fetch!(opts, :sweep)
    :ok = Cache.new(every)
    :ok = Group.join(Access, @group, %{})
    {:ok, schedule(%__MODULE__{grace: Keyword.fetch!(opts, :grace), every: every})}
  end

  @impl true
  def handle_call(:sweep, from, state),
    do: {:noreply, start_sweep(%{state | waiting: [from | state.waiting]})}

  @impl true
  def handle_info({:revoked, ref}, state) do
    revoke([ref], state.grace)
    {:noreply, state}
  end

  def handle_info(:sweep, state), do: {:noreply, start_sweep(state)}

  def handle_info({sweep, result}, %{sweep: sweep} = state) do
    Process.demonitor(sweep, [:flush])

    case result do
      {:gone, refs} ->
        revoke(refs, state.grace)

      :unavailable ->
        Logger.warning(
          "Held records cannot be read through consensus, so their holders are ended"
        )

        finish(held(), state.grace)
    end

    {:noreply, swept(state)}
  end

  def handle_info({:DOWN, sweep, :process, _pid, reason}, %{sweep: sweep} = state) do
    Logger.warning(
      "A sweep of held records failed, so their holders are ended: #{inspect(reason)}"
    )

    finish(held(), state.grace)
    {:noreply, swept(state)}
  end

  def handle_info({:kill, ending}, state) do
    for {{ns, key} = ref, pid} <- ending, holding?(ref, pid) do
      Logger.warning("#{inspect(pid)} held #{ns}/#{key} past its revocation, and was killed")
      Process.exit(pid, :kill)
    end

    {:noreply, state}
  end

  # A revoked record is refused here before its holders are looked up, so a
  # process that registers meanwhile either finds the refusal or is found.
  defp revoke(refs, grace) do
    for ref <- refs, do: Cache.revoked(ref)
    finish(refs, grace)
  end

  defp finish([], _grace), do: :ok

  defp finish(refs, grace) do
    ending =
      for ref <- refs, {pid, _id} <- Registry.lookup(@registry, ref), uniq: true, do: {ref, pid}

    for {_ref, pid} <- ending, do: Process.exit(pid, {:shutdown, :revoked})

    if ending != [],
      do: Process.send_after(self(), {:kill, ending}, grace)

    :ok
  end

  defp holding?(ref, pid),
    do: Enum.any?(Registry.lookup(@registry, ref), &match?({^pid, _id}, &1))

  # The sweep visits every lease held.
  # credo:disable-for-next-line Wardrik.Credo.Check.NoScans
  defp held, do: @registry |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.uniq()

  defp start_sweep(%{sweep: nil} = state) do
    refs = held()
    task = Task.Supervisor.async_nolink(@tasks, fn -> check(refs) end)
    %{state | sweep: task.ref}
  end

  defp start_sweep(state), do: state

  # {:gone, refs} for the records no longer written, keeping what was read of
  # the rest; :unavailable at the first that cannot be read.
  defp check(refs) do
    refs
    |> Task.async_stream(&{&1, Access.fetch(&1, timeout: @read_timeout)},
      max_concurrency: @concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.reduce_while({:gone, []}, fn
      {:ok, {ref, {:ok, value}}}, gone ->
        :ok = Cache.put(ref, value)
        {:cont, gone}

      {:ok, {ref, {:error, :not_found}}}, {:gone, refs} ->
        {:cont, {:gone, [ref | refs]}}

      {:ok, {_ref, {:error, :unavailable}}}, _gone ->
        {:halt, :unavailable}
    end)
  end

  defp swept(state) do
    :ok = Cache.purge()
    for from <- state.waiting, do: GenServer.reply(from, :ok)
    schedule(%{state | sweep: nil, waiting: []})
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :sweep, state.every)}
  end
end
