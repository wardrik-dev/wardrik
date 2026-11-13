defmodule WardrikDaemon.Doctor.Agents do
  @moduledoc false

  import WardrikDaemon.Doctor, only: [counted: 2]

  alias WardrikDaemon.AgentFile
  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Config
  alias WardrikDaemon.Dirs
  alias WardrikDaemon.Policies

  @doc "Returns a check for each file that doesn't read, or one saying they all did."
  @spec check(Config.t(), Dirs.t()) :: [WardrikDaemon.Doctor.check()]
  def check(config, dirs) do
    path = Dirs.config(dirs, "policies")

    case Policies.read(path) do
      {:ok, policies} -> agents(config, dirs, policies)
      {:error, why} -> [{:fail, "agents", why}]
    end
  end

  defp agents(config, dirs, policies) do
    files =
      dirs
      |> Dirs.config("agents")
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.sort()

    store = Wardrik.Store.ETS.new(name: :"wardrik doctor #{System.unique_integer([:positive])}")
    ulid = if Process.whereis(WardrikDaemon.ULID), do: [], else: [WardrikDaemon.ULID]

    {:ok, running} =
      Supervisor.start_link([{Wardrik.Store, store} | ulid], strategy: :one_for_one)

    wardrik = wardrik(config, policies, store)

    schema =
      "agent_definition"
      |> WardrikProtocol.schema()
      |> JSV.build!()

    records = Wardrik.Store.scope(store, "wardrik_daemon", format: Wardrik.Store.Format.Term)
    read = for path <- files, do: {path, recorded(records, AgentFile.read(path, config))}
    failures = Enum.flat_map(read, &unread(&1, records, wardrik, schema))
    :ok = Supervisor.stop(running)

    case failures do
      [] ->
        [
          {:ok, "agents",
           "#{counted(length(files), "agent file")} and #{counted(map_size(policies), "policy")} read"}
        ]

      failures ->
        failures
    end
  end

  # Each file has a name of its own, so none is taken.
  defp recorded(records, {:ok, agent, definition}) do
    {:ok, record} =
      AgentRecords.create(records, owner: agent.owner, name: agent.name, source: :file)

    {:ok, record, definition}
  end

  defp recorded(_records, {:error, why}), do: {:error, why}

  defp unread({path, read}, records, wardrik, schema) do
    with {:ok, record, definition} <- read,
         {:ok, definition} <- AgentRecords.identified(records, record.org, definition),
         {:ok, _valid} <- valid(definition, schema),
         {:ok, _opts} <- Wardrik.Resolution.resolve(wardrik, record.id, definition) do
      []
    else
      {:error, %Wardrik.Error{message: message}} ->
        [{:fail, "agents", "#{Path.basename(path)}: #{message}"}]

      {:error, why} ->
        [{:fail, "agents", "#{Path.basename(path)}: #{why}"}]
    end
  end

  # Resolves as the daemon does, but nothing is installed in a channel here, so nothing's looked up.
  defp resolving(config, policies, store) do
    %{
      org: config.org,
      orgs: config.orgs,
      policies: policies,
      wardrik: WardrikDaemon.Doctor,
      config: %{config | channels: []},
      store: Wardrik.Store.scope(store, "wardrik_daemon", format: Wardrik.Store.Format.Term)
    }
  end

  defp valid(definition, schema) do
    case JSV.validate(definition, schema) do
      {:ok, valid} ->
        {:ok, valid}

      {:error, error} ->
        {:error, %Wardrik.Error{type: :invalid_request, message: Exception.message(error)}}
    end
  end

  defp wardrik(config, policies, store) do
    daemon = Wardrik.Store.scope(store, "wardrik_daemon", format: Wardrik.Store.Format.Term)

    Wardrik.new(
      name: WardrikDaemon.Doctor,
      store: store,
      capabilities:
        WardrikDaemon.Capabilities.all(%{
          wardrik: WardrikDaemon.Doctor,
          store: daemon,
          orgs: %{org: config.org, orgs: config.orgs, policies: policies},
          config: config,
          dirs: nil,
          env: %{},
          web: nil
        }) ++
          WardrikDaemon.Harnesses.capabilities(WardrikDaemon.Doctor, daemon, config) ++
          WardrikDaemon.Rest.capabilities(WardrikDaemon.Doctor, daemon, config),
      mcp: config.mcp,
      channels: config.channels,
      defaults: config.defaults,
      policies: Map.to_list(policies),
      authorizer: {WardrikDaemon.Authorizer, %{access: config.access, store: daemon}},
      resolver: {WardrikDaemon.Resolver, resolving(config, policies, store)}
    )
  end
end
