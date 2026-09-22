defmodule TarsMCP.Supervisor do
  @moduledoc """
  The registry and the connections behind `TarsMCP`.

  A host starts it with the servers it wants reached, from the application
  environment:

      children = [TarsMCP.Supervisor]

  or as options, stated the way `config :tars, TarsMCP` states them:

      children = [
        {TarsMCP.Supervisor,
         servers: [github: [transport: {:stdio, command: "github-mcp-server"}]]}
      ]

  `:stderr` sets where every command's own output goes, for the servers that do
  not say for themselves. A surface drawing on the terminal wants this: see
  `TarsMCP.Server`.

  Every connection starts with the supervisor and keeps trying on its own, so a
  server that is down holds up neither the others nor the node, and one that
  crashes is restarted without disturbing the rest. `connect/1` and
  `disconnect/1` add and remove one while it runs.
  """

  use Supervisor

  alias TarsMCP.Connection
  alias TarsMCP.Server

  @registry TarsMCP.Registry
  @connections TarsMCP.Connections
  @principals TarsMCP.Principals

  @doc "Starts the registry and a connection for each configured server."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    servers = servers(opts)

    children =
      [{Registry, keys: :unique, name: @registry}, TarsMCP.Notifications] ++
        pool(servers) ++
        [
          {DynamicSupervisor, name: @principals, strategy: :one_for_one},
          connections(Enum.map(servers, &{Connection, &1}))
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Anubis reaches an HTTP server through a Finch pool it names and does not
  # start. Nothing else here needs one, so a deployment of commands runs none.
  defp pool(servers) do
    if Enum.any?(servers, &Server.http?/1), do: [{Finch, name: Anubis.Finch}], else: []
  end

  # The connections sit under one supervisor of their own so that a connection
  # that crashes restarts alone, while a registry that crashes takes every
  # connection with it: their registrations went with it.
  defp connections(children) do
    %{
      id: @connections,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [children, [strategy: :one_for_one, name: @connections, max_restarts: 10]]}
    }
  end

  @doc "Starts a connection to one more server."
  @spec connect(Server.t()) :: {:ok, pid()} | {:error, term()}
  def connect(%Server{} = server) do
    case Supervisor.start_child(@connections, {Connection, server}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, :already_present} -> restart(server.ref)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Starts a connection to `server` for one principal, over `transport`.

  A per-principal connection is transient: it stops when it has been idle, and
  is started again by the next call that needs it.
  """
  @spec connect(Server.t(), term(), Server.transport(), timeout()) ::
          {:ok, pid()} | {:error, term()}
  def connect(%Server{} = server, principal, transport, good_for \\ :infinity) do
    child = %{
      id: {Connection, server.ref, principal},
      start: {Connection, :start_link, [server, principal, transport, good_for]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(@principals, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stops the connection to a server, and forgets it."
  @spec disconnect(atom()) :: :ok | {:error, :not_found}
  def disconnect(ref) when is_atom(ref) do
    with :ok <- Supervisor.terminate_child(@connections, {Connection, ref}) do
      Supervisor.delete_child(@connections, {Connection, ref})
    end
  end

  @doc "The servers this supervisor is connecting to, whether or not they answer."
  @spec servers() :: [Server.t()]
  def servers do
    for ref <- Connection.refs(), offer = Connection.offer(ref), do: offer.server
  end

  defp restart(ref) do
    case Supervisor.restart_child(@connections, {Connection, ref}) do
      {:ok, pid} -> {:ok, pid}
      {:error, :running} -> {:error, :already_started}
      {:error, reason} -> {:error, reason}
    end
  end

  defp servers(opts) do
    defaults = Keyword.take(opts, [:stderr])

    opts
    |> Keyword.get_lazy(:servers, fn ->
      :tars |> Application.get_env(TarsMCP, []) |> Keyword.get(:servers, [])
    end)
    |> Enum.map(fn {ref, server_opts} ->
      Server.new(ref, Keyword.merge(defaults, server_opts))
    end)
  end
end
