defmodule WardrikMCP.Supervisor do
  @moduledoc """
  The registry and the connections behind `WardrikMCP`.

  A host starts it with the servers it wants reached, each a name and the
  options `WardrikMCP.Server.new/2` takes. They are the deployment's own,
  keyed by `Wardrik.Servers.Key.deployment/1`:

      children = [
        {WardrikMCP.Supervisor,
         servers: [github: [transport: {:stdio, command: "github-mcp-server"}]]}
      ]

  Options:

    * `:servers` - the servers to connect to, none by default
    * `:stderr` - where every command's own output goes, for the servers that
      do not say for themselves. A surface drawing on the terminal wants this:
      see `WardrikMCP.Server`.
    * `:first_retry`, `:refresh_after` - the same for how long a connection
      waits before listing a server's tools again; see `WardrikMCP.Server`
    * `:store` - the `WardrikStore` every server keeps the tools a user's
      connection listed in; see `WardrikMCP.Listing`. With one,
      `WardrikMCP.Remotes` runs too, reaching the servers owners added and
      keep there; see `WardrikMCP.Servers`
    * `:check` - whether the URL of a server an owner added may be reached;
      see `WardrikMCP.Remotes`

  Every connection starts with the supervisor and keeps trying on its own, so a
  server that is down holds up neither the others nor the node, and one that
  crashes is restarted without disturbing the rest. `connect/1` and
  `disconnect/1` add and remove one while it runs.
  """

  use Supervisor

  alias Wardrik.Servers.Key
  alias WardrikMCP.Connection
  alias WardrikMCP.Server

  @registry WardrikMCP.Registry
  @connections WardrikMCP.Connections
  @principals WardrikMCP.Principals
  @tasks WardrikMCP.TaskSupervisor

  @doc "Starts the registry and a connection for each configured server."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    servers = servers(opts)

    children =
      [
        {Registry, keys: :unique, name: @registry},
        {Task.Supervisor, name: @tasks},
        WardrikMCP.Notifications
      ] ++
        pool(servers, opts) ++
        [
          connections(Enum.map(servers, &{Connection, &1})),
          {DynamicSupervisor, name: @principals, strategy: :one_for_one}
        ] ++ remotes(opts)

    Supervisor.init(children, strategy: :rest_for_one)
  end

  # Anubis reaches an HTTP server through a Finch pool it names and does not
  # start. Nothing else here needs one, so a deployment of commands that
  # reaches no server an owner added runs none.
  defp pool(servers, opts) do
    if Enum.any?(servers, &Server.http?/1) or Keyword.has_key?(opts, :store),
      do: [{Finch, name: Anubis.Finch}],
      else: []
  end

  defp remotes(opts),
    do:
      if(Keyword.has_key?(opts, :store),
        do: [{WardrikMCP.Remotes, Keyword.take(opts, [:store, :check])}],
        else: []
      )

  # The connections sit under one supervisor of their own so that a connection
  # that crashes restarts alone, while a registry that crashes takes every
  # connection with it: their registrations went with it. Per-user connections
  # come after, so they stop before the deployment connections they publish
  # through.
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
      {:error, :already_present} -> restart(server.key)
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
      id: {Connection, server.key, principal},
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
  @spec disconnect(Key.t()) :: :ok | {:error, :not_found}
  def disconnect(%Key{} = key) do
    with :ok <- Supervisor.terminate_child(@connections, {Connection, key}) do
      Supervisor.delete_child(@connections, {Connection, key})
    end
  end

  @doc """
  The servers this supervisor was started with or `connect/1` added, whether
  or not they answer; not those `WardrikMCP.Remotes` started for owners.
  """
  @spec servers() :: [Server.t()]
  def servers do
    # The configured servers are this supervisor's children, and no other
    # record of them is kept.
    # credo:disable-for-next-line Wardrik.Credo.Check.NoScans
    for {{Connection, key}, pid, _type, _modules} <- Supervisor.which_children(@connections),
        is_pid(pid),
        offer = Connection.offer(key),
        do: offer.server
  catch
    :exit, {:noproc, _call} -> []
  end

  defp restart(key) do
    case Supervisor.restart_child(@connections, {Connection, key}) do
      {:ok, pid} -> {:ok, pid}
      {:error, :running} -> {:error, :already_started}
      {:error, reason} -> {:error, reason}
    end
  end

  defp servers(opts) do
    defaults = Keyword.take(opts, [:store, :stderr, :first_retry, :refresh_after])

    opts
    |> Keyword.get(:servers, [])
    |> Enum.map(fn {name, server_opts} ->
      Server.new(Key.deployment(Atom.to_string(name)), Keyword.merge(defaults, server_opts))
    end)
  end
end
