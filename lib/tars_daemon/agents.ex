defmodule TarsDaemon.Agents do
  @moduledoc """
  Runs the agents `agents/` in the config directory declares, one per `*.md`
  file. See `TarsDaemon.AgentFile` for what a file says.

  It reads every file when it starts and again on `reload/0`, and brings each
  agent in the fleet to what its file says: started where it is not running,
  and given the file's config and seams with `Tars.Agent.configure/2` where it
  is. An agent keeps its conversation either way.

  A file that does not read is reported by `files/0`, and by `tars status`,
  and an agent already running for it is left as it was. Removing a file stops
  nothing; `Tars.Fleet.forget/1` removes an agent and what it said.
  """

  use GenServer

  require Logger

  alias Tars.Agent
  alias Tars.Fleet
  alias TarsDaemon.AgentFile

  @typedoc "What became of one file: the agent it runs, or why it runs none."
  @type file() :: {Path.t(), {:ok, AgentFile.t()} | {:error, String.t()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, Keyword.fetch!(opts, :dir), name: __MODULE__)
  end

  @doc "Reads every file again and brings the fleet to what they say."
  @spec reload() :: [file()]
  def reload, do: GenServer.call(__MODULE__, :reload, :timer.minutes(1))

  @doc "What became of each file the last time they were read, in the order of their names."
  @spec files() :: [file()]
  def files, do: GenServer.call(__MODULE__, :files)

  @impl true
  def init(dir), do: {:ok, %{dir: dir, files: []}, {:continue, :load}}

  @impl true
  def handle_continue(:load, state), do: {:noreply, load(state)}

  @impl true
  def handle_call(:reload, _from, state) do
    state = load(state)
    {:reply, state.files, state}
  end

  def handle_call(:files, _from, state), do: {:reply, state.files, state}

  defp load(%{dir: dir} = state) do
    files =
      dir
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&{&1, run(AgentFile.read(&1))})

    for {_path, {:error, message}} <- files, do: Logger.error(message)

    %{state | files: files}
  end

  defp run({:ok, %AgentFile{key: key, opts: opts} = file}) do
    with {:ok, pid} <- Fleet.spawn(key, opts),
         :ok <- Agent.configure(pid, opts) do
      {:ok, file}
    else
      {:error, reason} -> {:error, "#{file.path}: #{key} did not start: #{inspect(reason)}"}
    end
  end

  defp run({:error, _message} = error), do: error
end
