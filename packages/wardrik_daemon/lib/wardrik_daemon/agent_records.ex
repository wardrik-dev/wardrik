defmodule WardrikDaemon.AgentRecords do
  @moduledoc """
  Keeps a record of each agent the daemon made.

      %{id: "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN", org: "acme", owner: "acme/@jon", name: "notes", source: :file}

    * IDs are `agt_` and a `WardrikDaemon.ULID`. Nothing is read from them.
    * `source` is `:file` for an agent an agent file declares, `:api` for one made through the API.
    * A name is unique in its org. Once an agent is gone, its name is free and a new agent of
      that name gets a new ID.
  """

  alias WardrikDaemon.Owners
  alias WardrikDaemon.ULID

  @name ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @type t() :: %{
          id: String.t(),
          org: String.t(),
          owner: String.t(),
          name: String.t(),
          source: :file | :api
        }

  @doc "Returns whether `name` is an agent's name: letters, digits, `_`, `.` and `-`, at most 64."
  @spec name?(term()) :: boolean()
  def name?(name), do: is_binary(name) and Regex.match?(@name, name)

  @doc """
  Returns the name `agent:NAME` names, as people write an agent.

      WardrikDaemon.AgentRecords.subject("agent:triage")
      #=> {:ok, "triage"}
  """
  @spec subject(term()) :: {:ok, String.t()} | :error
  def subject("agent:" <> name), do: if(name?(name), do: {:ok, name}, else: :error)
  def subject(_other), do: :error

  @doc "Returns whether `record` is of an agent an agent file declares."
  @spec file?(t()) :: boolean()
  def file?(%{source: :file}), do: true
  def file?(_record), do: false

  @doc "Returns the record of the agent `id`, or `:error` if the daemon made none."
  @spec fetch(Wardrik.Store.t(), String.t()) :: {:ok, t()} | :error
  def fetch(store, id) do
    case Wardrik.Store.get(store, record_key(id)) do
      %{id: ^id} = record -> {:ok, record}
      nil -> :error
    end
  end

  @doc "Returns the record of the agent called `name` in `org`, or `:error` if there's none."
  @spec named(Wardrik.Store.t(), String.t(), String.t()) :: {:ok, t()} | :error
  def named(store, org, name) do
    case Wardrik.Store.get(store, name_key(org, name)) do
      %{} = record -> {:ok, record}
      nil -> :error
    end
  end

  @doc "Returns the records of `org`'s agents, by name."
  @spec in_org(Wardrik.Store.t(), String.t()) :: [t()]
  def in_org(store, org),
    do: for({_key, record, _vsn} <- Wardrik.Store.entries(store, name_key(org, "")), do: record)

  @doc """
  Mints an ID for agent `:name`, owned by `:owner`, from `:source`, and records it.

  Returns `{:error, {:taken, record}}` if the name is taken in the org, unless `:replaces`
  returns `true` for that record.
  """
  @spec create(Wardrik.Store.t(),
          owner: String.t(),
          name: String.t(),
          source: :file | :api,
          replaces: (t() -> boolean())
        ) :: {:ok, t()} | {:error, {:taken, t()}}
  def create(store, args) do
    owner = Keyword.fetch!(args, :owner)
    name = Keyword.fetch!(args, :name)
    replaces = Keyword.get(args, :replaces, fn _record -> false end)

    record = %{
      id: "agt_" <> ULID.generate(),
      org: Owners.org(owner),
      owner: owner,
      name: name,
      source: Keyword.fetch!(args, :source)
    }

    with :ok <- claimed(store, name_key(record.org, name), record, replaces) do
      {:ok, _vsn} = Wardrik.Store.put(store, record_key(record.id), record)
      {:ok, record}
    end
  end

  # A name's claim holds its whole record, so whoever finds the name taken reads who holds it from
  # the claim itself, even where the record by ID hasn't reached this node yet. Taking a name over
  # writes only over the version read, so two can't both take it.
  defp claimed(store, key, record, replaces) do
    case Wardrik.Store.put(store, key, record, if_vsn: nil) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> held(store, key, record, replaces)
    end
  end

  defp held(store, key, record, replaces) do
    case Wardrik.Store.lookup(store, key) do
      nil -> claimed(store, key, record, replaces)
      {holder, vsn} -> held(store, {key, vsn}, record, replaces, holder)
    end
  end

  defp held(store, {key, vsn}, record, replaces, holder) do
    if replaces.(holder) do
      case Wardrik.Store.put(store, key, record, if_vsn: vsn) do
        {:ok, _vsn} -> dropped(store, holder)
        {:error, :conflict} -> claimed(store, key, record, replaces)
      end
    else
      {:error, {:taken, holder}}
    end
  end

  defp dropped(store, record), do: Wardrik.Store.delete(store, record_key(record.id))

  @doc """
  Returns `definition` with the agents its `workspace.shared` names, as `agent:NAME` in `org`,
  replaced by their IDs.

      AgentRecords.identified(store, "acme", %{"workspace" => %{"shared" => %{"books" => "agent:runbooks"}}})
      #=> {:ok, %{"workspace" => %{"shared" => %{"books" => "agt_01JF8X5RQ2M3V9ZK0B7Y4T6WHN"}}}}
  """
  @spec identified(Wardrik.Store.t(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def identified(store, org, %{"workspace" => %{"shared" => %{} = shared}} = definition) do
    mounts = for {mount, agent} <- shared, do: {mount, mounted(store, org, agent)}

    case Enum.find(mounts, &match?({_mount, :error}, &1)) do
      nil ->
        mounted = for {mount, {:ok, agent}} <- mounts, into: %{}, do: {mount, agent}
        {:ok, put_in(definition, ["workspace", "shared"], mounted)}

      {mount, :error} ->
        {:error, "workspace.shared.#{mount}: names no agent of #{org}, as agent:NAME"}
    end
  end

  def identified(_store, _org, definition), do: {:ok, definition}

  defp mounted(store, org, %{"agent" => name} = mount) do
    with {:ok, id} <- mounted(store, org, name), do: {:ok, %{mount | "agent" => id}}
  end

  defp mounted(store, org, written) when is_binary(written) do
    with {:ok, name} <- subject(written),
         {:ok, record} <- named(store, org, name),
         do: {:ok, record.id}
  end

  defp mounted(_store, _org, _other), do: :error

  @doc "Removes `record`, freeing its name."
  @spec delete(Wardrik.Store.t(), t()) :: :ok
  def delete(store, %{id: id} = record) do
    key = name_key(record.org, record.name)

    case Wardrik.Store.lookup(store, key) do
      {%{id: ^id}, vsn} -> _deleted = Wardrik.Store.delete(store, key, if_vsn: vsn)
      _other -> :ok
    end

    Wardrik.Store.delete(store, record_key(id))
  end

  defp record_key(id), do: "agents/" <> URI.encode_www_form(id)

  defp name_key(org, name),
    do: "agent_names/" <> URI.encode_www_form(org) <> "/" <> URI.encode_www_form(name)
end
