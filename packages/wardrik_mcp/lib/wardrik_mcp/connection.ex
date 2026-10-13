defmodule WardrikMCP.Connection do
  @moduledoc """
  One MCP server's connection: the client that talks to it, and the tools it
  last said it had.

  `WardrikMCP.Supervisor` starts one per configured `WardrikMCP.Server`, and
  `WardrikMCP.call/3` starts one more per owner of the credential a server is
  reached with. A connection is named by its server and the principal it acts
  for: `:deployment` for the one the supervisor starts, and `{:owner, owner}`
  for one carrying a credential, with the credential's `:owner`. It
  starts an `Anubis.Client` with the server's transport, asks for the server's
  tools, and registers them as a `WardrikMCP.Offer` so `WardrikMCP.tools/1` can
  read them without a call. A server that cannot be reached offers nothing and
  is asked again, backing off to a minute; a client that dies takes its tools
  out of the offer and is started again the same way, so a server that goes
  down and comes back needs nothing from anyone.

  A server reached as a user is different in both directions. The deployment
  has no credential for it, so a server that refuses to list its tools without
  one leaves nothing to offer and nothing to call to fix that; the deployment's
  connection offers the one tool that authorizes instead, and stops asking.
  Each user's own connection lists the real tools and hands them to the
  deployment's connection to publish, which is what replaces that one tool with
  the server's. It also keeps them with `WardrikMCP.Listing`, which offers them
  on every other connected node and to a deployment's connection that starts
  later, so a node no user has connected through offers the server's tools
  from the start. A per-user connection stops on its own once nothing has called
  through it for a quarter of an hour, and again when the credential it was
  built around is about to expire: the call after that resolves a fresh one
  and opens a connection carrying it.

  ## Cancelling what a caller stopped waiting for

  `Wardrik.LLM.ToolRunner` ends a tool call by killing the task, which leaves the
  server working on a request nobody will read. A caller asks to be watched
  with `watch/1` before it calls; the connection monitors it, and when it dies
  of anything but its own success the connection tells the server to cancel
  whatever that caller had in flight. A call that ends normally needs nothing:
  its exit reason says so.
  """

  use GenServer

  require Logger

  alias WardrikMCP.Listing
  alias WardrikMCP.Offer
  alias WardrikMCP.Server
  alias WardrikMCP.Tool

  @registry WardrikMCP.Registry
  @max_retry_ms :timer.minutes(1)
  @list_timeout :timer.seconds(30)
  @ready_timeout :timer.seconds(30)
  @watch_timeout :timer.seconds(5)
  @offer_timeout :timer.seconds(30)
  @idle_after :timer.minutes(15)
  # A connection torn down as its credential expires, rather than after, so no
  # call goes out with a token the server has already stopped taking.
  @expiry_margin_ms :timer.seconds(30)

  defmodule State do
    @moduledoc false

    @enforce_keys [:server, :principal, :transport]
    defstruct [
      :server,
      :principal,
      :transport,
      :client,
      :retry_ms,
      :used_at,
      listed?: false,
      refreshing?: false,
      idling?: false,
      waiting: [],
      watching: %{}
    ]

    @type t() :: %__MODULE__{
            server: Server.t(),
            principal: term(),
            transport: Server.transport(),
            client: pid() | nil,
            retry_ms: pos_integer() | nil,
            used_at: integer() | nil,
            listed?: boolean(),
            refreshing?: boolean(),
            idling?: boolean(),
            waiting: [GenServer.from()],
            watching: %{reference() => pid()}
          }
  end

  @doc false
  def child_spec(%Server{} = server) do
    %{id: {__MODULE__, server.ref}, start: {__MODULE__, :start_link, [server]}}
  end

  @doc "Starts the deployment's own connection to `server`."
  @spec start_link(Server.t()) :: GenServer.on_start()
  def start_link(%Server{} = server), do: start_link(server, :deployment, server.transport)

  @doc "Stops the connection a principal was using, if there is one."
  @spec close(atom(), term()) :: :ok
  def close(ref, principal) do
    case GenServer.whereis(name(ref, principal)) do
      nil -> :ok
      connection -> GenServer.stop(connection, :normal)
    end
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Starts a connection to `server` for one principal, over `transport`.

  What `WardrikMCP.call/3` uses for a server each user reaches as themselves: the
  transport is the server's own, carrying that user's credential.
  """
  @spec start_link(Server.t(), term(), Server.transport(), timeout()) :: GenServer.on_start()
  def start_link(%Server{} = server, principal, transport, good_for \\ :infinity) do
    GenServer.start_link(__MODULE__, {server, principal, transport, good_for},
      name: name(server.ref, principal)
    )
  end

  @doc """
  What a server is offering, or `nil` when nothing is connected under that ref.

  A connection that has stopped offers nothing from the moment it stops, before
  the registry has dropped its entry.
  """
  @spec offer(atom()) :: Offer.t() | nil
  def offer(ref) do
    case Registry.lookup(@registry, {:offer, ref}) do
      [{pid, %Offer{} = offer}] -> if Process.alive?(pid), do: offer
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "The tools a server last reported."
  @spec tools(atom()) :: [ReqLLM.Tool.t()]
  def tools(ref) do
    case offer(ref) do
      %Offer{tools: tools} -> tools
      nil -> []
    end
  end

  @doc """
  The refs of every server a connection is running for, leaving out one that
  has stopped and is still to leave the registry.

  Empty on a host that started no registry, which is one running no MCP
  servers at all.
  """
  @spec refs() :: [atom()]
  def refs do
    @registry
    # Every server offered is the answer.
    # credo:disable-for-next-line Wardrik.Credo.Check.NoScans
    |> Registry.select([{{{:offer, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    |> Enum.flat_map(fn {ref, pid} -> if Process.alive?(pid), do: [ref], else: [] end)
    |> Enum.sort()
  rescue
    ArgumentError -> []
  end

  @doc "The refs a principal has a connection to, as the registry holds them."
  @spec refs_for(pid()) :: [{atom(), term()}]
  def refs_for(client) when is_pid(client) do
    for {:client, ref, principal} <- Registry.keys(@registry, client), do: {ref, principal}
  rescue
    ArgumentError -> []
  end

  @doc "The `Anubis.Client` name for a ref and principal, whether or not it is running."
  @spec client(atom(), term()) :: GenServer.name()
  def client(ref, principal \\ :deployment),
    do: {:via, Registry, {@registry, {:client, ref, principal}}}

  @doc "The connection running for this server and principal, or `nil`."
  @spec whereis(atom(), term()) :: pid() | nil
  def whereis(ref, principal \\ :deployment), do: GenServer.whereis(name(ref, principal))

  @doc "Whether a connection is running for this server and principal."
  @spec running?(atom(), term()) :: boolean()
  def running?(ref, principal), do: not is_nil(whereis(ref, principal))

  @doc """
  Asks a server for its tools again.

  A connection that is not running is not asked, and the tools it last
  reported stand until it is. Asking again while a listing is already due
  costs nothing: the one already due answers both.
  """
  @spec refresh(atom(), term()) :: :ok
  def refresh(ref, principal \\ :deployment),
    do: GenServer.cast(name(ref, principal), :list_tools)

  @doc """
  Offers the `tools/list` entries a user's connection on another node got
  from `ref`, in place of the tool that authorizes.

  What `WardrikMCP.Listing.remember/3` runs on every other connected node. A node
  with no connection to `ref`, or one that reaches it as the deployment, is
  left as it is.
  """
  @spec offer_listing(atom(), [map()]) :: :ok
  def offer_listing(ref, listed) when is_atom(ref) and is_list(listed),
    do: GenServer.cast(name(ref, :deployment), {:offer_listing, listed})

  @doc """
  Waits until a server has reported its tools, and hands them back.

  Returns `{:error, :timeout}` when it has not answered in time, which a server
  that is down never will.
  """
  @spec await(atom(), term(), timeout()) :: {:ok, [ReqLLM.Tool.t()]} | {:error, :timeout}
  def await(ref, principal \\ :deployment, timeout \\ :timer.seconds(30)) do
    GenServer.call(name(ref, principal), :await, timeout)
  catch
    :exit, {:timeout, _call} -> {:error, :timeout}
    :exit, reason -> {:error, reason}
  end

  @doc """
  Asks the connection to cancel this caller's requests if the caller dies.

  Returns once the connection is watching, so a request is never sent
  unwatched. A connection that is busy or missing answers `:ok` all the same:
  the call still runs, and only its cancellation is lost.
  """
  @spec watch(atom(), term()) :: :ok
  def watch(ref, principal \\ :deployment) do
    case GenServer.whereis(name(ref, principal)) do
      nil -> :ok
      connection -> GenServer.call(connection, {:watch, self()}, @watch_timeout)
    end
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init({%Server{} = server, principal, transport, good_for}) do
    # The client is linked, and a server that keeps dying should back off here
    # rather than crash-loop under the supervisor.
    Process.flag(:trap_exit, true)

    if principal == :deployment do
      {tools, read_only} = remembered(server)
      offer = %Offer{server: server, tools: tools, read_only: read_only}
      {:ok, _pid} = Registry.register(@registry, {:offer, server.ref}, offer)
    end

    state = %State{
      server: server,
      principal: principal,
      transport: transport,
      used_at: System.monotonic_time(:millisecond)
    }

    {:ok, expire_with_credential(state, good_for), {:continue, :connect}}
  end

  @impl GenServer
  def handle_continue(:connect, %State{} = state) do
    case start_client(state) do
      {:ok, client} ->
        {:noreply, %{state | client: client}, {:continue, :list_tools}}

      {:error, reason} ->
        {:noreply, retry(state, "could not be started: #{inspect(reason)}")}
    end
  end

  def handle_continue(:list_tools, %State{} = state) do
    case ready(state) do
      :ok -> {:noreply, list_tools(state)}
      {:error, reason} -> {:noreply, retry(state, "did not finish the handshake: #{reason}")}
    end
  end

  @impl GenServer
  def handle_call(:await, _from, %State{listed?: true} = state) do
    {:reply, {:ok, tools(state.server.ref)}, state}
  end

  def handle_call(:await, from, %State{} = state) do
    {:noreply, %{state | waiting: [from | state.waiting]}}
  end

  def handle_call({:offer, tools}, _from, %State{server: server} = state) do
    offer(server, tools)

    {:reply, :ok, state}
  end

  def handle_call({:watch, caller}, _from, %State{} = state) do
    monitor = Process.monitor(caller)
    watching = Map.put(state.watching, monitor, caller)

    {:reply, :ok, %{state | watching: watching, used_at: System.monotonic_time(:millisecond)}}
  end

  @impl GenServer
  def handle_cast({:offer, tools}, %State{server: server} = state) do
    offer(server, tools)

    {:noreply, state}
  end

  def handle_cast({:offer_listing, _listed}, %State{server: %Server{credential: nil}} = state),
    do: {:noreply, state}

  def handle_cast({:offer_listing, listed}, %State{server: server} = state) do
    offer(server, built(server, listed))

    {:noreply, state}
  end

  def handle_cast(:list_tools, %State{client: nil} = state), do: {:noreply, state}
  def handle_cast(:list_tools, %State{refreshing?: true} = state), do: {:noreply, state}

  def handle_cast(:list_tools, %State{} = state) do
    # A server that registers its tools one at a time says so once per tool,
    # and the listing that answers waits, so a burst costs one call.
    Process.send_after(self(), :refresh, state.server.refresh_after)

    {:noreply, %{state | refreshing?: true}}
  end

  @impl GenServer
  def handle_info(:refresh, %State{client: nil} = state),
    do: {:noreply, %{state | refreshing?: false}}

  def handle_info(:refresh, %State{} = state),
    do: {:noreply, list_tools(%{state | refreshing?: false})}

  def handle_info(:retry, %State{client: nil} = state),
    do: {:noreply, state, {:continue, :connect}}

  def handle_info(:retry, %State{} = state), do: {:noreply, list_tools(state)}

  def handle_info({:DOWN, monitor, :process, _pid, :normal}, %State{} = state) do
    {:noreply, %{state | watching: Map.delete(state.watching, monitor)}}
  end

  def handle_info({:DOWN, monitor, :process, caller, _stopped}, %State{} = state) do
    cancel_for(state, caller)

    {:noreply, %{state | watching: Map.delete(state.watching, monitor)}}
  end

  def handle_info({:EXIT, client, reason}, %State{client: client} = state) do
    {:noreply, retry(%{state | client: nil, listed?: false}, "stopped: #{inspect(reason)}")}
  end

  def handle_info({:EXIT, _pid, _reason}, %State{} = state), do: {:noreply, state}

  def handle_info(:expired, %State{} = state) do
    Logger.info("MCP server #{state.server.ref}: a user's credential expired; closing")

    {:stop, :normal, state}
  end

  def handle_info(:idle_check, %State{} = state) do
    if idle_for(state) >= @idle_after and state.watching == %{} do
      {:stop, :normal, state}
    else
      {:noreply, schedule_idle_check(%{state | idling?: false})}
    end
  end

  defp list_tools(%State{} = state) do
    case ask(state) do
      {:ok, %Anubis.MCP.Response{result: %{"tools" => listed}}} when is_list(listed) ->
        publish(state, listed)
        %{state | retry_ms: nil, listed?: true} |> answer_waiting() |> schedule_idle_check()

      {:ok, %Anubis.MCP.Response{result: result}} ->
        retry(state, "answered tools/list with #{inspect(result)}")

      {:error, reason} ->
        retry(state, "could not be asked for its tools: #{reason}")
    end
  end

  defp ready(%State{} = state) do
    state |> client_of() |> Anubis.Client.await_ready(timeout: @ready_timeout)
    :ok
  catch
    :exit, reason -> {:error, inspect(reason)}
  end

  defp ask(%State{} = state) do
    state |> client_of() |> Anubis.Client.list_tools(timeout: @list_timeout)
  catch
    :exit, reason -> {:error, inspect(reason)}
  else
    {:error, %Anubis.MCP.Error{} = error} -> {:error, describe(error)}
    other -> other
  end

  defp describe(%Anubis.MCP.Error{} = error) do
    "#{error.message} (#{error.reason})"
  end

  # The offer belongs to the deployment's connection, and a registry value is
  # the owner's to change, so a user's connection hands its list over.
  defp publish(%State{principal: :deployment, server: server} = state, listed) do
    offer(server, built(server, listed))
    listed(state, listed)

    Logger.info("MCP server #{server.ref}: #{length(listed)} tools listed")
  end

  defp publish(%State{server: server} = state, listed) do
    hand_over(server, built(server, listed))
    Listing.remember(server.store, server.ref, listed)
    listed(state, listed)

    Logger.info("MCP server #{server.ref}: #{length(listed)} tools listed as a user")
  end

  # `[:wardrik_mcp, :connection, :listed]` says a server's tools were published,
  # with the ref and principal in its metadata.
  defp listed(%State{server: server, principal: principal}, listed) do
    :telemetry.execute(
      [:wardrik_mcp, :connection, :listed],
      %{count: length(listed)},
      %{ref: server.ref, principal: principal}
    )
  end

  # The hand-over is waited on: a caller told a user's connection is ready
  # reads the offer next, and the tools it was told about are in it. A
  # deployment's connection too busy to answer is told rather than asked, so a
  # listing is late rather than lost.
  defp hand_over(%Server{} = server, tools) do
    GenServer.call(name(server.ref, :deployment), {:offer, tools}, @offer_timeout)
  catch
    :exit, reason ->
      Logger.warning(
        "MCP server #{server.ref}: a user's tools wait to be published: #{inspect(reason)}"
      )

      GenServer.cast(name(server.ref, :deployment), {:offer, tools})
  end

  # The tools a listing offers, and the remote names of those it marks
  # read-only.
  defp built(%Server{} = server, listed) do
    offered = for %{"name" => name} = entry <- listed, Server.offers?(server, name), do: entry

    {Enum.map(offered, &Tool.build(server, &1)),
     for(%{"name" => name, "annotations" => %{"readOnlyHint" => true}} <- offered, do: name)}
  end

  defp remembered(%Server{credential: nil}), do: {[], []}
  defp remembered(%Server{} = server), do: built(server, Listing.recall(server.store, server.ref))

  defp offer(%Server{} = server, {tools, read_only}) do
    Registry.update_value(
      @registry,
      {:offer, server.ref},
      &%{&1 | tools: tools, read_only: read_only}
    )
  end

  defp offer(%Server{} = server, tools), do: offer(server, {tools, []})

  # Cancelling is a call into the client with a timeout of its own, and this
  # process answers every tool build, so it does not wait for it here.
  defp cancel_for(%State{} = state, caller) do
    client = client_of(state)
    Task.Supervisor.start_child(WardrikMCP.TaskSupervisor, fn -> cancel(client, caller) end)

    :ok
  end

  # Best effort: a client that has gone away since the caller died has nothing
  # left to cancel, and a server that ignores the notification is within spec.
  defp cancel(client, caller) do
    for id <- in_flight_for(client, caller) do
      Anubis.Client.cancel_request(client, id, "the tool call was stopped")
    end
  catch
    :exit, _reason -> :ok
  end

  # Anubis mints request ids itself and does not report them, so the pending
  # request a caller was waiting on is read from the client's own state. Replace
  # this with whatever the library exposes once it exposes anything.
  defp in_flight_for(client, caller) do
    case GenServer.whereis(client) do
      nil ->
        []

      pid ->
        pid
        |> :sys.get_state()
        |> Anubis.Client.State.list_pending_requests()
        |> Enum.filter(&match?({^caller, _tag}, &1.from))
        |> Enum.map(& &1.id)
    end
  catch
    :exit, _reason -> []
  end

  defp answer_waiting(%State{} = state) do
    tools = tools(state.server.ref)
    Enum.each(state.waiting, &GenServer.reply(&1, {:ok, tools}))

    %{state | waiting: []}
  end

  defp start_client(%State{server: server, principal: principal} = state) do
    Anubis.Client.start_link(
      name: client_of(state),
      transport_name: {:via, Registry, {@registry, {:transport, server.ref, principal}}},
      transport: state.transport,
      client_info: client_info(state),
      capabilities: %{}
    )
  end

  # Anubis names a private ETS table after the client's name, so two clients
  # sharing one break each other's responses. The principal is hashed rather
  # than named: a server has no business knowing who is behind a connection
  # beyond the token it was given.
  defp client_info(%State{server: server, principal: :deployment}) do
    %{"name" => "Wardrik (#{server.ref})", "version" => version()}
  end

  defp client_info(%State{server: server, principal: principal}) do
    %{"name" => "Wardrik (#{server.ref}##{:erlang.phash2(principal)})", "version" => version()}
  end

  defp client_of(%State{server: server, principal: principal}), do: client(server.ref, principal)

  defp expire_with_credential(%State{} = state, :infinity), do: state

  defp expire_with_credential(%State{} = state, good_for) when is_integer(good_for) do
    Process.send_after(self(), :expired, max(good_for - @expiry_margin_ms, 0))

    state
  end

  defp schedule_idle_check(%State{principal: :deployment} = state), do: state
  defp schedule_idle_check(%State{idling?: true} = state), do: state

  # One check runs at a time: a connection listed again on every notification
  # would otherwise carry a timer per listing for as long as it lives.
  defp schedule_idle_check(%State{} = state) do
    Process.send_after(self(), :idle_check, @idle_after)

    %{state | idling?: true}
  end

  defp idle_for(%State{used_at: used_at}),
    do: System.monotonic_time(:millisecond) - used_at

  # A server reached as a user, refusing the deployment: there is nothing to
  # retry with, so it offers the tool that authorizes and waits to be told.
  # Where a user's connection has already published the server's own tools, on
  # this node or another, those stand: the deployment is refused whatever the
  # tools are.
  defp retry(%State{principal: :deployment, server: %Server{credential: credential}} = state, why)
       when credential != nil do
    Logger.info("MCP server #{state.server.ref} #{why}; offering to authorize instead")
    if tools(state.server.ref) == [], do: offer(state.server, [Tool.connect(state.server)])

    answer_waiting(%{state | listed?: true})
  end

  # `[:wardrik_mcp, :connection, :retrying]` says a server could not be listed
  # and will be asked again, with the ref, principal and trouble in its metadata.
  defp retry(%State{} = state, trouble) do
    delay = min((state.retry_ms || state.server.first_retry) * 2, @max_retry_ms)

    Logger.warning("MCP server #{state.server.ref} #{trouble}; asking again in #{delay}ms")
    if state.principal == :deployment, do: offer(state.server, [])
    Process.send_after(self(), :retry, delay)

    :telemetry.execute(
      [:wardrik_mcp, :connection, :retrying],
      %{delay_ms: delay},
      %{ref: state.server.ref, principal: state.principal, trouble: trouble}
    )

    %{state | retry_ms: delay}
  end

  defp name(ref, principal), do: {:via, Registry, {@registry, {:connection, ref, principal}}}

  defp version, do: :wardrik |> Application.spec(:vsn) |> to_string()
end
