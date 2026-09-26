defmodule TarsOAuth.Pending do
  @moduledoc """
  The authorizations that have been started and not yet come back.

  One entry per `state` value: what was being authorized, for whom, the PKCE
  verifier the callback needs, or the code a user enters on another device,
  where to send the user, and the calls parked waiting for it. Entries expire
  after fifteen minutes, or when a device code does, because a user who never
  finishes should not leave a verifier lying around, and a second attempt
  should start clean.

  A flow already under way for the same user and provider is handed back
  rather than started again, so an agent that retries a parked call keeps
  offering the same URL. A flow that has expired can no longer be claimed.
  `inspect/1` of a flow shows what it is for, never its verifier, client,
  URL or code.
  """

  use GenServer

  alias TarsOAuth.Flow
  alias TarsOAuth.Metadata
  alias TarsOAuth.Provider

  @sweep_every :timer.minutes(1)

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
      expires_after: :timer.minutes(15),
      resumes: []
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
            expires_after: pos_integer(),
            resumes: [Tars.Credential.continuation()]
          }
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Remembers a flow, and answers with the URL the user is sent to."
  @spec start(Flight.t()) :: {:ok, String.t()}
  def start(%Flight{} = flight), do: GenServer.call(__MODULE__, {:start, flight})

  @doc """
  The flow under way for this provider and owner, if any.

  A continuation is added to the flow it finds, so every call that parks while
  one authorization runs is answered by the callback that ends it.
  """
  @spec under_way(String.t(), term(), Tars.Credential.continuation() | nil) ::
          {:ok, Flight.t()} | :error
  def under_way(provider, owner, resume \\ nil),
    do: GenServer.call(__MODULE__, {:under_way, provider, owner, resume})

  @doc """
  Takes the flow a callback belongs to, which can only be claimed once, where
  it has not expired and `accept` takes it. One `accept` refuses is left
  where it is.
  """
  @spec claim(String.t(), (Flight.t() -> boolean())) :: {:ok, Flight.t()} | :error
  def claim(state, accept \\ fn _flight -> true end),
    do: GenServer.call(__MODULE__, {:claim, state, accept})

  @doc "Forgets a flow that will not be finished."
  @spec drop(String.t()) :: :ok
  def drop(state), do: GenServer.cast(__MODULE__, {:drop, state})

  @doc "Forgets every flow under way for this provider and owner."
  @spec drop(String.t(), term()) :: :ok
  def drop(provider, owner), do: GenServer.cast(__MODULE__, {:drop, provider, owner})

  @doc """
  The flow under way for this provider and owner on any of `nodes`, joined as
  `under_way/3` joins one here, with `resume` added to it where it is held. A
  node that cannot be asked, or runs no registry of flows, is passed over.
  """
  @spec under_way_on([node()], String.t(), term(), Tars.Credential.continuation() | nil) ::
          {:ok, Flight.t()} | :error
  def under_way_on(nodes, provider, owner, resume) do
    nodes
    |> :erpc.multicall(__MODULE__, :under_way, [provider, owner, resume], :timer.seconds(5))
    |> Enum.find_value(:error, fn
      {:ok, {:ok, %Flight{} = flight}} -> {:ok, flight}
      _none -> nil
    end)
  end

  @doc "Forgets every flow under way for this provider and owner, here and on `nodes`."
  @spec drop_on([node()], String.t(), term()) :: :ok
  def drop_on(nodes, provider, owner) do
    :ok = drop(provider, owner)
    :erpc.multicast(nodes, __MODULE__, :drop, [provider, owner])
  end

  @impl GenServer
  def init(_opts) do
    Process.send_after(self(), :sweep, @sweep_every)

    {:ok, %{}}
  end

  @impl GenServer
  def handle_call({:start, %Flight{} = flight}, _from, flights) do
    {:reply, {:ok, flight.url}, Map.put(flights, flight.state, flight)}
  end

  def handle_call({:under_way, provider, owner, resume}, _from, flights) do
    found =
      Enum.find_value(flights, :error, fn {_state, flight} ->
        if flight.provider.name == provider and flight.owner == owner and
             not expired?(flight),
           do: {:ok, flight}
      end)

    case found do
      {:ok, flight} ->
        waiting = %{flight | resumes: add(flight.resumes, resume)}

        {:reply, {:ok, waiting}, Map.put(flights, waiting.state, waiting)}

      :error ->
        {:reply, :error, flights}
    end
  end

  def handle_call({:claim, state, accept}, _from, flights) do
    case Map.fetch(flights, state) do
      {:ok, flight} ->
        if not expired?(flight) and accept.(flight),
          do: {:reply, {:ok, flight}, Map.delete(flights, state)},
          else: {:reply, :error, flights}

      :error ->
        {:reply, :error, flights}
    end
  end

  @impl GenServer
  def handle_cast({:drop, state}, flights), do: {:noreply, Map.delete(flights, state)}

  def handle_cast({:drop, provider, owner}, flights) do
    {:noreply,
     Map.reject(flights, fn {_state, flight} ->
       flight.provider.name == provider and flight.owner == owner
     end)}
  end

  @impl GenServer
  def handle_info(:sweep, flights) do
    Process.send_after(self(), :sweep, @sweep_every)

    {:noreply, Map.reject(flights, fn {_state, flight} -> expired?(flight) end)}
  end

  defp add(resumes, nil), do: resumes
  defp add(resumes, resume), do: if(resume in resumes, do: resumes, else: resumes ++ [resume])

  defp expired?(%Flight{started_at: started_at, expires_after: expires_after}) do
    System.monotonic_time(:millisecond) - started_at > expires_after
  end
end
