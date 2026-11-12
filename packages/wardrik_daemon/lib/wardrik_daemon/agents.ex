defmodule WardrikDaemon.Agents do
  @moduledoc """
  Defines the agents in `agents/`. It's the daemon's `Wardrik.Declarations`.

  On reload:

    * if `config.yaml` or `policies/` changed, the daemon restarts.
    * a changed file's agent gets its new definition and keeps its ID.
    * a removed file's agent is forgotten.
    * a file that doesn't read keeps its last definition, and the log says why.
    * a file can't take a name another agent of its org has, nor change its agent's owner.
    * nodes reloading at once give a new file one agent: the first to claim its name.

  The API can't forget an agent a file declares.

  ## Options

    * `:wardrik` - the Wardrik.
    * `:dir` - the `agents/` directory.
    * `:config` - the `WardrikDaemon.Config`.
    * `:restart` - restarts the daemon if `config.yaml` or `policies/` changed. Returns whether it did.
    * `:store` - where it keeps agents' records.
  """

  @behaviour Wardrik.Declarations

  require Logger

  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Config.Access

  @key "agent files"

  @impl Wardrik.Declarations
  def declared?(opts, id), do: id in Map.values(declared(opts))

  @impl Wardrik.Declarations
  def reload(opts) do
    restart = opts[:restart] || fn -> false end
    if restart.(), do: [], else: defined_all(opts)
  end

  defp defined_all(opts) do
    last = declared(opts)
    read = for path <- files(opts), do: {path, claimed(opts, path, last)}

    declared =
      for {path, result} <- read,
          file = Path.basename(path),
          id = declares(result, last[file]),
          into: %{},
          do: {file, id}

    gone = Enum.uniq(Map.values(last)) -- Map.values(declared)

    {:ok, _vsn} = Wardrik.Store.put(opts[:store], @key, declared)
    problems = Enum.map(read, &defined(opts, &1)) ++ Enum.map(gone, &forgotten(opts, &1))
    for problem <- problems, problem != :ok, do: logged(problem)
  end

  defp logged(problem) do
    Logger.warning("Wardrik #{problem}")
    problem
  end

  @doc "Returns the scope agents are defined in: the deployment's admin's. See `WardrikDaemon.Config.Access`."
  @spec scope(keyword()) :: Wardrik.Scope.t()
  def scope(opts), do: Wardrik.as(opts[:wardrik], Access.admin())

  defp files(opts), do: opts[:dir] |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()

  defp declared(opts), do: Wardrik.Store.get(opts[:store], @key) || %{}

  # The file's agent keeps the ID a file gave it. A new one gets a new ID, unless another agent
  # has its name.
  defp claimed(opts, path, last) do
    with {:ok, agent, definition} <- AgentFile.read(path, opts[:config]) do
      case AgentRecords.named(opts[:store], agent.org, agent.name) do
        {:ok, record} -> kept(opts, {agent, definition}, record, record.id in Map.values(last))
        :error -> created(opts, {agent, definition})
      end
    end
  end

  defp kept(_opts, {%{owner: owner}, definition}, %{owner: owner} = record, true),
    do: {:ok, record, definition}

  defp kept(_opts, {agent, _definition}, record, true),
    do:
      {:error,
       "#{agent.name} is #{record.owner}'s agent. Remove its file and reload before giving it to #{agent.owner}."}

  defp kept(opts, declared, _record, false), do: created(opts, declared)

  # A name an agent made through the API has stays its own while the agent is defined. A name
  # another node's reload claimed for this file is this file's agent, defined or not yet.
  defp created(opts, {agent, definition}) do
    case AgentRecords.create(opts[:store],
           owner: agent.owner,
           name: agent.name,
           source: :file,
           replaces: &(not same_file?(&1, agent) and gone?(opts, &1))
         ) do
      {:ok, record} ->
        {:ok, record, definition}

      {:error, {:taken, record}} ->
        if same_file?(record, agent),
          do: {:ok, record, definition},
          else: {:error, "#{agent.name} is the name of another agent in #{agent.org}."}
    end
  end

  defp same_file?(record, agent), do: AgentRecords.file?(record) and record.owner == agent.owner

  @doc "Returns whether the agent of `record` is gone: forgotten, or never defined."
  @spec gone?(keyword(), AgentRecords.t()) :: boolean()
  def gone?(opts, record),
    do:
      match?(
        {:error, %Wardrik.Error{type: :not_found}},
        Wardrik.run(scope(opts), "agent.definition", %{"agent" => record.id})
      )

  defp declares({:ok, record, _definition}, _last), do: record.id
  defp declares({:error, _why}, last), do: last

  defp defined(_opts, {path, {:error, why}}), do: "didn't read an agent. #{path}: #{why}"

  defp defined(opts, {path, {:ok, record, definition}}) do
    with {:ok, definition} <- AgentRecords.identified(opts[:store], record.org, definition),
         {:ok, _snapshot} <-
           Wardrik.run(scope(opts), "agent.define", Map.put(definition, "agent", record.id)) do
      :ok
    else
      {:error, %Wardrik.Error{message: message}} ->
        "didn't define #{record.name}. #{path}: #{message}"

      {:error, why} ->
        "didn't define #{record.name}. #{path}: #{why}"
    end
  end

  defp forgotten(opts, id) do
    case Wardrik.run(scope(opts), "agent.forget", %{"agent" => id}) do
      {:error, %Wardrik.Error{type: type} = error} when type != :not_found ->
        "didn't forget #{id}, whose file is gone: #{error.message}"

      _forgotten ->
        with {:ok, record} <- AgentRecords.fetch(opts[:store], id),
             do: AgentRecords.delete(opts[:store], record)

        :ok
    end
  end
end
