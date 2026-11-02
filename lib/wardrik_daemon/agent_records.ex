defmodule WardrikDaemon.AgentRecords do
  @moduledoc """
  Keeps a record of each agent the daemon made: its ID, org, owner and name.

      %{id: "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN", org: "acme", owner: "acme/@jon", name: "notes"}

  The daemon mints each ID, as `agt_` and a `WardrikDaemon.ULID`, and never reads anything from
  it. A name is unique in its org. `WardrikDaemon.Owners` reads who owns an agent from here.

  A record outlives an agent forgotten through the API. Its name is free again once the agent
  is gone, and the next agent of that name gets a new ID.
  """

  alias WardrikDaemon.Owners
  alias WardrikDaemon.ULID

  @name ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @type t() :: %{id: String.t(), org: String.t(), owner: String.t(), name: String.t()}

  @doc "Returns whether `name` is an agent's name: letters, digits, `_`, `.` and `-`, at most 64."
  @spec name?(term()) :: boolean()
  def name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc "Returns the record of the agent `id`, or `:error` if the daemon made none."
  @spec fetch(WardrikStore.t(), String.t()) :: {:ok, t()} | :error
  def fetch(store, id) do
    case WardrikStore.get(store, "agents/" <> URI.encode_www_form(id)) do
      %{id: ^id} = record -> {:ok, record}
      nil -> :error
    end
  end

  @doc "Returns the record of the agent called `name` in `org`, or `:error` if there's none."
  @spec named(WardrikStore.t(), String.t(), String.t()) :: {:ok, t()} | :error
  def named(store, org, name) do
    case WardrikStore.get(store, name_key(org, name)) do
      nil -> :error
      id -> fetch(store, id)
    end
  end

  @doc "Returns the records of `org`'s agents, by name."
  @spec in_org(WardrikStore.t(), String.t()) :: [t()]
  def in_org(store, org) do
    ids = for {_key, id, _vsn} <- WardrikStore.entries(store, name_key(org, "")), do: id
    for id <- ids, {:ok, record} <- [fetch(store, id)], do: record
  end

  @doc """
  Mints an ID for the agent `:name`, owned by `:owner`, and records it.

  Returns `{:error, {:taken, record}}` if another agent has the name in the owner's org. Unless
  `:replaces` returns `true` for that record: then it's dropped, and the name taken.
  """
  @spec create(WardrikStore.t(),
          owner: String.t(),
          name: String.t(),
          replaces: (t() -> boolean())
        ) :: {:ok, t()} | {:error, {:taken, t()}}
  def create(store, args) do
    owner = Keyword.fetch!(args, :owner)
    name = Keyword.fetch!(args, :name)
    replaces = Keyword.get(args, :replaces, fn _record -> false end)
    record = %{id: "agt_" <> ULID.generate(), org: Owners.org(owner), owner: owner, name: name}
    key = name_key(record.org, name)

    with :ok <- claimed(store, key, record.id, replaces) do
      {:ok, _vsn} = WardrikStore.put(store, "agents/" <> URI.encode_www_form(record.id), record)
      {:ok, record}
    end
  end

  # Taking a name over writes only over the version read, so two can't both take it.
  defp claimed(store, key, id, replaces) do
    case WardrikStore.put(store, key, id, if_vsn: nil) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> held(store, key, id, replaces)
    end
  end

  defp held(store, key, id, replaces) do
    case WardrikStore.lookup(store, key) do
      nil -> claimed(store, key, id, replaces)
      {held, vsn} -> held(store, {key, vsn}, id, replaces, record(store, held))
    end
  end

  defp held(store, {key, vsn}, id, replaces, record) do
    if record == nil or replaces.(record) do
      case WardrikStore.put(store, key, id, if_vsn: vsn) do
        {:ok, _vsn} -> dropped(store, record)
        {:error, :conflict} -> claimed(store, key, id, replaces)
      end
    else
      {:error, {:taken, record}}
    end
  end

  defp record(store, id) do
    case fetch(store, id) do
      {:ok, record} -> record
      :error -> nil
    end
  end

  defp dropped(_store, nil), do: :ok

  defp dropped(store, record),
    do: WardrikStore.delete(store, "agents/" <> URI.encode_www_form(record.id))

  @doc """
  Returns `definition` with the agents it names by name, in `org`, named by their IDs. Those are
  the agents whose workspaces its `workspace.shared` mounts.

      AgentRecords.identified(store, "acme", %{"workspace" => %{"shared" => %{"books" => "runbooks"}}})
      #=> {:ok, %{"workspace" => %{"shared" => %{"books" => "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN"}}}}
  """
  @spec identified(WardrikStore.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def identified(store, org, %{"workspace" => %{"shared" => %{} = shared}} = definition) do
    mounts = for {mount, agent} <- shared, do: {mount, mounted(store, org, agent)}

    case Enum.find(mounts, &match?({_mount, :error}, &1)) do
      nil ->
        mounted = for {mount, {:ok, agent}} <- mounts, into: %{}, do: {mount, agent}
        {:ok, put_in(definition, ["workspace", "shared"], mounted)}

      {mount, :error} ->
        {:error, "workspace.shared.#{mount}: names no agent of #{org}"}
    end
  end

  def identified(_store, _org, definition), do: {:ok, definition}

  defp mounted(store, org, %{"agent" => name} = mount) do
    with {:ok, id} <- mounted(store, org, name), do: {:ok, %{mount | "agent" => id}}
  end

  defp mounted(store, org, name) when is_binary(name) do
    with {:ok, record} <- named(store, org, name), do: {:ok, record.id}
  end

  defp mounted(_store, _org, _other), do: :error

  @doc "Removes `record`, freeing its name."
  @spec delete(WardrikStore.t(), t()) :: :ok
  def delete(store, %{id: id} = record) do
    key = name_key(record.org, record.name)

    case WardrikStore.lookup(store, key) do
      {^id, vsn} -> _deleted = WardrikStore.delete(store, key, if_vsn: vsn)
      _other -> :ok
    end

    WardrikStore.delete(store, "agents/" <> URI.encode_www_form(id))
  end

  defp name_key(org, name),
    do: "agent_names/" <> URI.encode_www_form(org) <> "/" <> URI.encode_www_form(name)
end
