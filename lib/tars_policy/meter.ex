defmodule TarsPolicy.Meter do
  @moduledoc """
  One budget period's `TarsPolicy.Spend`, owned by one process across the
  cluster.

  A meter is a `DurableServer` keyed by `TarsPolicy.Spend.key/2`, started on
  whichever node asks for it first and found there by every node after. Every
  spend and grant for the period is a call to that one process, so they are
  counted in order, however many delegations settle at once, with no lock and
  nothing retried. Each is written to `Tars.Store` before the call returns.

  A meter nothing has used for #{div(:timer.minutes(10), 60_000)} minutes stops, leaving its spend in
  the store, and the next call starts it again from there, on any node. So a
  period that has ended costs no process, and one whose node is lost carries on
  elsewhere at its next call.

  The host starts `TarsPolicy.Supervisor`, which runs the meters.
  """

  use DurableServer, vsn: 1

  alias TarsPolicy.Spend

  @name TarsPolicy.Meters
  @idle :timer.minutes(10)
  @attempts 3

  @doc false
  @spec supervisor() :: atom()
  def supervisor, do: @name

  @doc "What has been spent and granted under `key`."
  @spec read(String.t()) :: {:ok, Spend.t()} | {:error, term()}
  def read(key), do: call(key, :read)

  @doc "Adds `micro_usd` and `tokens` to what has been spent under `key`."
  @spec spend(String.t(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def spend(key, micro_usd, tokens), do: call(key, {:spend, micro_usd, tokens})

  @doc "Adds `micro_usd` and `tokens` to what people have granted under `key`."
  @spec grant(String.t(), non_neg_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def grant(key, micro_usd, tokens), do: call(key, {:grant, micro_usd, tokens})

  # A meter may stop for being idle between being found and being called, so
  # a call that finds it gone finds it again.
  defp call(key, message, attempt \\ 1) do
    with {:ok, pid} <- ensure(key) do
      GenServer.call(pid, message)
    end
  rescue
    # The meters' supervisor is not running on this node.
    ArgumentError -> {:error, {:meter_unavailable, :not_started}}
  catch
    :exit, _reason when attempt < @attempts -> call(key, message, attempt + 1)
    :exit, reason -> {:error, {:meter_unavailable, reason}}
  end

  defp ensure(key) do
    child = {__MODULE__, key: key, initial_state: %Spend{}}

    case DurableServer.Supervisor.ensure_started_child(@name, child) do
      {:ok, {pid, _meta}} -> {:ok, pid}
      {:error, reason} -> {:error, {:meter_unavailable, reason}}
    end
  end

  # -- durability ------------------------------------------------------------

  @impl DurableServer
  def dump_state(%Spend{} = spend), do: Map.from_struct(spend)

  @impl DurableServer
  def load_state(_old_vsn, dumped), do: struct!(Spend, dumped)

  @impl DurableServer
  def init(%Spend{} = spend), do: {:ok, touch(spend)}

  @impl DurableServer
  def handle_call(:read, _from, spend), do: {:reply, {:ok, spend}, touch(spend)}

  def handle_call({:spend, micro_usd, tokens}, _from, spend),
    do: {:reply, :ok, spend |> Spend.spend(micro_usd, tokens) |> touch(), sync: true}

  def handle_call({:grant, micro_usd, tokens}, _from, spend),
    do: {:reply, :ok, spend |> Spend.grant(micro_usd, tokens) |> touch(), sync: true}

  @impl DurableServer
  def handle_info({:idle, since}, spend) do
    if Process.get(:touched) == since, do: {:stop, :normal, spend}, else: {:noreply, spend}
  end

  # Only the last message sent after the last use stops the meter.
  defp touch(spend) do
    now = System.monotonic_time()
    Process.put(:touched, now)
    Process.send_after(self(), {:idle, now}, @idle)
    spend
  end
end
