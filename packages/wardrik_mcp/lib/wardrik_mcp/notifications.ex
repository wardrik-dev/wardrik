defmodule WardrikMCP.Notifications do
  @moduledoc """
  A server's own word that its tools have changed, turned into a fresh listing.

  A server declaring `tools.listChanged` sends `notifications/tools/list_changed`
  whenever what it offers changes. Anubis answers that notification with
  telemetry and nothing else, and the telemetry carries no client, so the
  handler runs in the client process that received it and reads the connection
  it belongs to out of the registry.

  `WardrikMCP.Supervisor` starts one of these, next to the registry it reads.
  """

  use GenServer

  require Logger

  alias WardrikMCP.Connection

  @event [:anubis_mcp, :client, :notification]

  @doc "Starts listening for the servers' notifications."
  @spec start_link([]) :: GenServer.on_start()
  def start_link([]), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc false
  @spec handle(:telemetry.event_name(), map(), map(), term()) :: :ok
  def handle(@event, _measurements, %{method: "tools/list_changed"}, _config) do
    for {key, principal} <- Connection.keys_for(self()) do
      Logger.info("MCP server #{key}: said its tools changed; asking again")
      Connection.refresh(key, principal)
    end

    :ok
  end

  def handle(_event, _measurements, _metadata, _config), do: :ok

  @impl GenServer
  def init([]) do
    Process.flag(:trap_exit, true)

    case :telemetry.attach(__MODULE__, @event, &__MODULE__.handle/4, nil) do
      :ok -> {:ok, %{}}
      {:error, :already_exists} -> {:ok, %{}}
    end
  end

  @impl GenServer
  def terminate(_reason, _state), do: :telemetry.detach(__MODULE__)
end
