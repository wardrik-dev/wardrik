defmodule TarsOAuth.Pending do
  @moduledoc """
  The authorizations that have been started and not yet come back.

  One entry per `state` value: what was being authorized, for whom, the PKCE
  verifier the callback needs, and where to send the token when it arrives.
  Entries expire, because a user who never finishes should not leave a verifier
  lying around, and a second attempt should start clean.

  A flow already under way for the same user and provider is handed back
  rather than started again, so an agent that retries a parked call keeps
  offering the same URL.
  """

  use GenServer

  alias TarsOAuth.Flow
  alias TarsOAuth.Metadata
  alias TarsOAuth.Provider

  @sweep_every :timer.minutes(1)
  @expire_after :timer.minutes(15)

  defmodule Flight do
    @moduledoc false

    @enforce_keys [
      :state,
      :provider,
      :owner,
      :metadata,
      :registered,
      :verifier,
      :url,
      :started_at
    ]
    defstruct [:state, :provider, :owner, :metadata, :registered, :verifier, :url, :started_at]

    @type t() :: %__MODULE__{
            state: String.t(),
            provider: Provider.t(),
            owner: term(),
            metadata: Metadata.t(),
            registered: Flow.registered(),
            verifier: String.t(),
            url: String.t(),
            started_at: integer()
          }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Remembers a flow, and answers with the URL the user is sent to."
  @spec start(Flight.t()) :: {:ok, String.t()}
  def start(%Flight{} = flight), do: GenServer.call(__MODULE__, {:start, flight})

  @doc "The flow under way for this provider and owner, if any."
  @spec under_way(String.t(), term()) :: {:ok, Flight.t()} | :error
  def under_way(provider, owner), do: GenServer.call(__MODULE__, {:under_way, provider, owner})

  @doc "Takes the flow a callback belongs to, which can only be claimed once."
  @spec claim(String.t()) :: {:ok, Flight.t()} | :error
  def claim(state), do: GenServer.call(__MODULE__, {:claim, state})

  @doc "Forgets a flow that will not be finished."
  @spec drop(String.t()) :: :ok
  def drop(state), do: GenServer.cast(__MODULE__, {:drop, state})

  @impl GenServer
  def init(_opts) do
    Process.send_after(self(), :sweep, @sweep_every)

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:start, %Flight{} = flight}, _from, flights) do
    {:reply, {:ok, flight.url}, Map.put(flights, flight.state, flight)}
  end

  def handle_call({:under_way, provider, owner}, _from, flights) do
    found =
      Enum.find_value(flights, :error, fn {_state, flight} ->
        if flight.provider.name == provider and flight.owner == owner and
             not expired?(flight),
           do: {:ok, flight}
      end)

    {:reply, found, flights}
  end

  def handle_call({:claim, state}, _from, flights) do
    case Map.pop(flights, state) do
      {nil, flights} -> {:reply, :error, flights}
      {flight, flights} -> {:reply, {:ok, flight}, flights}
    end
  end

  @impl GenServer
  def handle_cast({:drop, state}, flights), do: {:noreply, Map.delete(flights, state)}

  @impl GenServer
  def handle_info(:sweep, flights) do
    Process.send_after(self(), :sweep, @sweep_every)

    {:noreply, Map.reject(flights, fn {_state, flight} -> expired?(flight) end)}
  end

  defp expired?(%Flight{started_at: started_at}) do
    System.monotonic_time(:millisecond) - started_at > @expire_after
  end
end
