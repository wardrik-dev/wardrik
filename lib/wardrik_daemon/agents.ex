defmodule WardrikDaemon.Agents do
  @moduledoc """
  Defines the agents in `agents/`. It's the daemon's `Wardrik.Declarations`.

  On each reload, if `config.yaml` or `policies/` changed since the daemon started, the daemon
  restarts to read them, and defines the agents as it starts. Otherwise:

    * an agent whose file reads is defined from it.
    * an agent whose file is gone is forgotten, and its name is free.
    * an agent whose file doesn't read keeps its last definition, and the log says why.

  A new file's agent gets a new ID, minted by `WardrikDaemon.AgentRecords`. It keeps that ID as
  long as the file keeps its name, org and owner. A file can't take a name another agent has in
  its org, unless a file declared that agent; nor can it give its agent another owner.

  Agents named in a file's `workspace.shared` are agents of its own org, by name.

  The API can't forget an agent a file declares.

  ## Options

    * `:wardrik` - what Wardrik is reached by.
    * `:dir` - the `agents/` directory.
    * `:config` - the `WardrikDaemon.Config` read as the daemon started.
    * `:restart` - restarts the daemon if `config.yaml` or `policies/` changed since it started.
      Returns whether it does.
    * `:store` - where it keeps which agents the files declare, and their records.
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

    {:ok, _vsn} = WardrikStore.put(opts[:store], @key, declared)
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

  defp declared(opts), do: WardrikStore.get(opts[:store], @key) || %{}

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

  # A name an agent made through the API has stays its own while the agent is defined.
  defp created(opts, {agent, definition}) do
    case AgentRecords.create(opts[:store],
           owner: agent.owner,
           name: agent.name,
           replaces: &gone?(opts, &1)
         ) do
      {:ok, record} ->
        {:ok, record, definition}

      {:error, {:taken, _record}} ->
        {:error,
         "#{agent.name} is the name of another agent in #{agent.org}, made through the API."}
    end
  end

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
