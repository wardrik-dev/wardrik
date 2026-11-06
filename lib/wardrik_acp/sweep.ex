defmodule WardrikACP.Sweep do
  @moduledoc false
  use GenServer

  alias WardrikACP.Connection
  alias WardrikACP.Worktree

  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(settings),
    do: %{id: __MODULE__, start: {__MODULE__, :start_link, [settings]}}

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(settings), do: GenServer.start_link(__MODULE__, settings)

  @doc """
  Removes each worktree whose work is in its checkout's base, and its branch. A worktree stays
  while a call uses its coding agent, while a request waits, or while it has changes or untracked
  files. An idle coding agent is stopped first. Returns the paths removed.
  """
  @spec run(map()) :: [Path.t()]
  def run(settings) do
    removed =
      for checkout <- Map.values(settings.checkouts),
          :ok <- [Worktree.fetch(checkout)],
          worktree <- Worktree.list(checkout, settings.worktrees),
          idle?(settings.acp, worktree.path),
          Worktree.merged?(worktree),
          :ok <- [Worktree.remove(worktree)] do
        File.rm(worktree.path <> ".json")
        worktree.path
      end

    Enum.each(Map.values(settings.checkouts), &Worktree.prune/1)

    :telemetry.execute([:wardrik_acp, :sweep], %{removed: length(removed)}, %{
      acp: settings.acp,
      removed: removed
    })

    removed
  end

  # A coding agent with nothing to do is stopped, so its worktree can go.
  defp idle?(acp, path) do
    stopped =
      case Registry.lookup(Connection.registry(acp), path) do
        [] -> :ok
        [{pid, _value}] -> Connection.stop_idle(pid)
      end

    stopped == :ok and not waiting?(path)
  end

  defp waiting?(path) do
    with {:ok, body} <- File.read(path <> ".json"),
         {:ok, %{"pending" => pending}} <- JSON.decode(body) do
      pending != nil
    else
      _none -> false
    end
  end

  @impl GenServer
  def init(settings) do
    send(self(), :sweep)
    {:ok, settings}
  end

  @impl GenServer
  def handle_info(:sweep, settings) do
    run(settings)
    Process.send_after(self(), :sweep, settings.sweep)
    {:noreply, settings}
  end
end
