defmodule WardrikOAuth.Pending do
  @moduledoc """
  The authorizations that have been started and not yet come back, one
  process each.

  A flow's process holds what is being authorized, for whom, the PKCE
  verifier the callback needs, or the code a user enters on another device,
  and where to send the user. It is registered across the cluster in a
  `Group` of this package's own, under its `state` value and under its
  provider and owner, so any node finds it by key: a callback by the state it
  carries, a parked call by who it is for. Only one flow is under way for a
  user and provider.

  A flow ends after fifteen minutes, or when its device code does, because a
  user who never finishes should not leave a verifier lying around, and a
  second attempt should start clean. Dropping a flow stops its process, and
  with it any polling; a flow that crashes takes only itself.

  A device flow's process asks the token endpoint every interval the server
  named, and never more often than `WardrikOAuth.Config.poll_floor/0`,
  whether the user has entered the code, until they have, refused, or let it
  expire. A server that cannot be reached, or fails, is asked again at the
  next interval. What it found is handed to the `:done` function it was
  started with, and the flow ends.

  `inspect/1` of a flow shows what it is for, never its verifier, client,
  URL or code.
  """

  use GenServer, restart: :temporary

  require Logger

  alias WardrikOAuth.Config
  alias WardrikOAuth.Device
  alias WardrikOAuth.Flow
  alias WardrikOAuth.Metadata
  alias WardrikOAuth.Provider
  alias WardrikOAuth.Token

  @flows __MODULE__.Supervisor

  defmodule Flight do
    @moduledoc false

    @derive {Inspect, only: [:provider, :owner, :started_at, :expires_after]}

    @enforce_keys [:state, :provider, :owner, :metadata, :registered, :url, :started_at]
    defstruct [
      :state,
      :provider,
      :owner,
      :metadata,
      :registered,
      :verifier,
      :user_code,
      :url,
      :started_at,
      expires_after: :timer.minutes(15)
    ]

    @type t() :: %__MODULE__{
            state: String.t(),
            provider: Provider.t(),
            owner: term(),
            metadata: Metadata.t(),
            registered: Flow.registered(),
            verifier: String.t() | nil,
            user_code: String.t() | nil,
            url: String.t(),
            started_at: integer(),
            expires_after: pos_integer()
          }
  end

  @typedoc "How a device flow ended: with a token, or why not."
  @type outcome() :: {:ok, Token.t()} | {:error, term()}

  @doc """
  What runs the flows: the `Group` they are registered in and the supervisor
  they run under, the registry first.
  """
  @spec children() :: [{module(), keyword()}]
  def children, do: [{Group, name: __MODULE__}, {DynamicSupervisor, name: @flows}]

  @doc """
  Starts a flow, and answers with the URL the user is sent to.

  A device flow is started with `:device`, the server's answer, and `:done`,
  called in the flow's process with the flow and its `t:outcome/0` once
  polling finds an end.
  """
  @spec start(Flight.t(), keyword()) :: {:ok, String.t()}
  def start(%Flight{} = flight, opts \\ []) do
    init = %{
      flight: flight,
      device: Keyword.get(opts, :device),
      done: Keyword.get(opts, :done),
      callers: [self() | Process.get(:"$callers", [])]
    }

    {:ok, _pid} = DynamicSupervisor.start_child(@flows, {__MODULE__, init})
    {:ok, flight.url}
  end

  @doc false
  def start_link(init), do: GenServer.start_link(__MODULE__, init)

  @doc "The flow under way for this provider and owner, on any node, if any."
  @spec under_way(String.t(), term()) :: {:ok, Flight.t()} | :error
  def under_way(provider, owner) do
    case lookup(owner_key(provider, owner)) do
      {_pid, flight} -> {:ok, flight}
      nil -> :error
    end
  end

  @doc """
  Takes the flow a callback belongs to, which can only be claimed once, where
  it has not expired and `accept` takes it. One `accept` refuses is left
  where it is. A claimed flow is still under way until it is dropped, or
  released to be claimed again.
  """
  @spec claim(String.t(), (Flight.t() -> boolean())) :: {:ok, Flight.t()} | :error
  def claim(state, accept \\ fn _flight -> true end) do
    with {pid, flight} <- lookup(state_key(state)),
         true <- accept.(flight) do
      ask(pid, :claim)
    else
      _none -> :error
    end
  end

  @doc "Lets a claimed flow that got no token be claimed again."
  @spec release(String.t()) :: :ok
  def release(state) do
    with {pid, _flight} <- lookup(state_key(state)), do: GenServer.cast(pid, :release)
    :ok
  end

  @doc "Stops the flow under way for this provider and owner, wherever it runs."
  @spec drop(String.t(), term()) :: :ok
  def drop(provider, owner) do
    with {pid, _flight} <- lookup(owner_key(provider, owner)),
         do: DynamicSupervisor.terminate_child({@flows, node(pid)}, pid)

    :ok
  end

  # Group forgets a process once it hears it has gone; one of this node's
  # that has gone already is not handed out meanwhile.
  defp lookup(key) do
    case Group.lookup(__MODULE__, key) do
      {pid, %Flight{}} = found when node(pid) != node() -> found
      {pid, %Flight{}} = found -> if Process.alive?(pid), do: found
      nil -> nil
    end
  end

  # A flow can end, expired or dropped, between being found and being asked.
  defp ask(pid, request) do
    GenServer.call(pid, request)
  catch
    :exit, _gone -> :error
  end

  defp state_key(state), do: "state/" <> state

  defp owner_key(provider, owner) do
    key = :erlang.term_to_binary({provider, owner}, [:deterministic])
    "owner/" <> Base.url_encode64(key, padding: false)
  end

  @impl GenServer
  def init(%{flight: %Flight{} = flight} = init) do
    Process.put(:"$callers", init.callers)
    Process.flag(:trap_exit, true)
    :ok = Group.register(__MODULE__, state_key(flight.state), flight)
    :ok = Group.register(__MODULE__, owner_key(flight.provider.name, flight.owner), flight)
    Process.send_after(self(), :expire, max(deadline(flight) - now(), 0))

    state = %{flight: flight, claimed?: false, device: init.device, done: init.done}
    {:ok, polling(state)}
  end

  defp polling(%{device: nil} = state), do: state

  defp polling(%{device: %Device{} = device} = state) do
    interval = max(:timer.seconds(device.interval), Config.poll_floor())
    next_poll(Map.put(state, :interval, interval))
  end

  @impl GenServer
  def handle_call(:claim, _from, %{flight: flight, claimed?: false} = state) do
    if now() > deadline(flight),
      do: {:reply, :error, state},
      else: {:reply, {:ok, flight}, %{state | claimed?: true}}
  end

  def handle_call(:claim, _from, state), do: {:reply, :error, state}

  @impl GenServer
  def handle_cast(:release, state), do: {:noreply, %{state | claimed?: false}}

  @impl GenServer
  def handle_info(:expire, %{device: nil} = state), do: {:stop, :normal, state}
  def handle_info(:expire, state), do: ended(state, {:error, :expired})

  def handle_info(:poll, %{flight: flight} = state) do
    if now() >= deadline(flight),
      do: ended(state, {:error, :expired}),
      else: poll(state)
  end

  defp poll(%{flight: flight, device: device} = state) do
    case Device.poll(flight.metadata, flight.registered, device) do
      {:ok, %Token{} = token} ->
        ended(state, {:ok, token})

      {:error, reason} ->
        ended(state, {:error, reason})

      {:retry, reason} ->
        Logger.info(
          "#{flight.provider.name} could not be polled (#{inspect(reason)}); asking again"
        )

        {:noreply, next_poll(state)}

      waiting ->
        {:noreply, next_poll(%{state | interval: Device.next_interval(waiting, state.interval)})}
    end
  end

  # The flow is no longer under way once it has ended, so whatever its end
  # sets off finds none.
  defp ended(%{flight: flight, done: done} = state, outcome) do
    unregister(flight)
    done.(flight, outcome)
    {:stop, :normal, state}
  end

  # Dropped or expired, a flow gives its keys up as it stops, so one started
  # for the same user and provider straight after takes them.
  @impl GenServer
  def terminate(_reason, %{flight: flight}), do: unregister(flight)

  defp unregister(%Flight{} = flight) do
    Group.unregister(__MODULE__, state_key(flight.state))
    Group.unregister(__MODULE__, owner_key(flight.provider.name, flight.owner))
    :ok
  end

  defp next_poll(%{flight: flight, interval: interval} = state) do
    Process.send_after(self(), :poll, min(interval, max(deadline(flight) - now(), 0)))
    state
  end

  defp deadline(%Flight{started_at: started_at, expires_after: expires_after}),
    do: started_at + expires_after

  defp now, do: System.monotonic_time(:millisecond)
end
