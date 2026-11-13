defmodule Wardrik.Triggers.Records do
  @moduledoc false

  alias Wardrik.Triggers.Trigger

  @prefix "triggers/"

  @doc """
  Returns the record for trigger `:name` of `:agent_id` and its version, or `nil`.

      Records.lookup(store, agent_id: "agt_digest", name: "daily")
  """
  @spec lookup(Wardrik.Store.t(), agent_id: String.t(), name: String.t()) ::
          {map(), Wardrik.Store.vsn()} | nil
  def lookup(store, args), do: Wardrik.Store.lookup(store, key(args))

  @doc """
  Writes `record` if the stored version is `vsn`. Pass `nil` to create it.

  Returns `{:error, :conflict}` if the version differs.
  """
  @spec put(Wardrik.Store.t(), map(), Wardrik.Store.vsn() | nil) ::
          :ok | {:error, :conflict | term()}
  def put(store, %{"agent_id" => agent_id, "trigger" => %{"name" => name}} = record, vsn) do
    with {:ok, _vsn} <- Wardrik.Store.put(store, key(agent_id, name), record, if_vsn: vsn),
         do: :ok
  end

  @doc "Deletes trigger `:name` of `:agent_id`."
  @spec delete(Wardrik.Store.t(), agent_id: String.t(), name: String.t()) ::
          :ok | {:error, term()}
  def delete(store, args), do: Wardrik.Store.delete(store, key(args))

  @doc "Returns every stored trigger as `{agent_id, name}`."
  @spec all(Wardrik.Store.t()) :: [{String.t(), String.t()}]
  def all(store) do
    store
    |> Wardrik.Store.keys(@prefix)
    |> Enum.map(&parsed/1)
  end

  @doc "Returns the trigger names of `agent_id`."
  @spec of(Wardrik.Store.t(), String.t()) :: [String.t()]
  def of(store, agent_id) do
    for key <- Wardrik.Store.keys(store, prefix(agent_id)),
        {^agent_id, name} <- [parsed(key)],
        do: name
  end

  @doc "Returns the records of `agent_id`'s triggers, by name."
  @spec records(Wardrik.Store.t(), String.t()) :: [map()]
  def records(store, agent_id),
    do: for({_key, record, _vsn} <- Wardrik.Store.entries(store, prefix(agent_id)), do: record)

  @doc "Returns every stored record."
  @spec records(Wardrik.Store.t()) :: [map()]
  def records(store),
    do: for({_key, record, _vsn} <- Wardrik.Store.entries(store, @prefix), do: record)

  @doc "Returns the record's trigger."
  @spec trigger(map()) :: Trigger.t()
  def trigger(%{"trigger" => fields}) do
    {:ok, trigger} = Trigger.decode(fields)
    trigger
  end

  @doc "Returns the record's next run, or `nil` for a webhook."
  @spec next_at(map()) :: DateTime.t() | nil
  def next_at(%{"next_at" => nil}), do: nil

  def next_at(%{"next_at" => text}) do
    {:ok, next_at, _offset} = DateTime.from_iso8601(text)
    next_at
  end

  @doc """
  Updates the record for trigger `:name` of `:agent_id` with `fun`. Retries on a conflicting
  write.

      Records.update(store, [agent_id: "agt_digest", name: "daily"], &Map.put(&1, "feeds", %{}))

  Returns `{:error, :not_found}` if there's no record.
  """
  @spec update(Wardrik.Store.t(), [agent_id: String.t(), name: String.t()], (map() -> map())) ::
          :ok | {:error, term()}
  def update(store, args, fun) do
    case lookup(store, args) do
      nil ->
        {:error, :not_found}

      {record, vsn} ->
        case put(store, fun.(record), vsn) do
          {:error, :conflict} -> update(store, args, fun)
          done -> done
        end
    end
  end

  defp key(args), do: key(Keyword.fetch!(args, :agent_id), Keyword.fetch!(args, :name))
  defp key(agent_id, name), do: prefix(agent_id) <> name
  defp prefix(agent_id), do: @prefix <> URI.encode_www_form(agent_id) <> "/"

  defp parsed(@prefix <> rest) do
    [agent_id, name] = String.split(rest, "/", parts: 2)
    {URI.decode_www_form(agent_id), name}
  end
end
