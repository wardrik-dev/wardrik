defmodule WardrikMCP.Listing do
  @moduledoc """
  The tools a server reached as a user last listed to one of its users, kept
  for every node.

  A user's connection hands what it listed to `remember/3`, which writes it to
  its server's store under `namespace/0` and offers it to the deployment's
  connection on every other connected node. A deployment's connection that
  starts later reads it back with `recall/2`. Either way a node no user has connected
  through offers the server's own tools, and a call to one opens the calling
  user's connection there.

  A host running no store keeps nothing: its connections offer the tool that
  authorizes until a user connects through them.
  """

  require Logger
  alias Wardrik.Servers.Key
  alias WardrikMCP.Connection

  @ns :mcp_tools

  @doc "The namespace listings are written under in `WardrikStore`."
  @spec namespace() :: WardrikStore.ns()
  def namespace, do: @ns

  @doc """
  Keeps the `tools/list` entries a user's connection got from the server
  `key`, and offers them on every other connected node.

  A listing the store already holds is not written again.
  """
  @spec remember(WardrikStore.t(), Key.t(), [map()]) :: :ok
  def remember(store, %Key{} = key, listed) when is_list(listed) do
    if recall(store, key) != listed, do: write(store, key, listed)

    :erpc.multicast(Node.list(), Connection, :offer_listing, [key, listed])
  end

  @doc "The `tools/list` entries last kept for the server `key`, or `[]`."
  @spec recall(WardrikStore.t(), Key.t()) :: [map()]
  def recall(store, %Key{} = key) do
    case stored(fn -> WardrikStore.get(store, @ns, to_string(key)) end) do
      listed when is_list(listed) -> listed
      _nothing -> []
    end
  end

  defp write(store, key, listed) do
    case stored(fn -> WardrikStore.put(store, @ns, to_string(key), listed) end) do
      {:ok, _vsn} ->
        :ok

      trouble ->
        Logger.warning("MCP server #{key}: its tools could not be kept: #{inspect(trouble)}")
    end
  end

  # A host that names no store raises, as EKV does where its instance was
  # never started and a read of `WardrikStore.Memory` does; a write to it exits.
  defp stored(fun) do
    fun.()
  rescue
    error in ArgumentError -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end
end
