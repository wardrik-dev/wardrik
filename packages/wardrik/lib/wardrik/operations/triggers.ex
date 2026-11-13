defmodule Wardrik.Operations.Triggers do
  @moduledoc false

  require Logger

  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Running
  alias Wardrik.Scope
  alias Wardrik.Triggers.Trigger

  @doc """
  Sets one of the agent's triggers, and saves it in the agent's definition. Returns the trigger
  with its next run, if it has one, as `"next_at"` in its time zone.
  """
  @spec set(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def set(%Scope{wardrik: wardrik} = scope, %{"agent" => id, "trigger" => name} = input) do
    fields = input |> Map.drop(["agent", "trigger"]) |> Map.put("name", name)

    with {:ok, definition} <- Running.definition(wardrik, id),
         :ok <- Wardrik.Resolution.trigger(wardrik, definition, fields, 1),
         {:ok, trigger} <- set_trigger(wardrik, id, fields),
         :ok <- saved(wardrik, id, Map.put(definition, "triggers", replaced(definition, fields))) do
      Changes.record(scope,
        type: "trigger.set",
        agent: id,
        data: %{"trigger" => %{"name" => name}}
      )

      {:ok, next(wardrik, id, trigger)}
    end
  end

  @doc "Removes one of the agent's triggers. Returns the removed trigger."
  @spec remove(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def remove(%Scope{wardrik: wardrik} = scope, %{"agent" => id, "trigger" => name}) do
    with {:ok, definition} <- Running.definition(wardrik, id),
         {:ok, trigger} <- kept(wardrik, id, name),
         :ok <- removed(wardrik, id, name),
         :ok <- saved(wardrik, id, Map.put(definition, "triggers", without(definition, name))) do
      Changes.record(scope,
        type: "trigger.removed",
        agent: id,
        data: %{"trigger" => %{"name" => name}}
      )

      {:ok, Trigger.encode(trigger)}
    end
  end

  @doc """
  Removes a trigger that won't run again from the agent and its definition. A failure is logged:
  the trigger stays listed, and never runs.
  """
  @spec ended(Wardrik.t(), String.t(), String.t()) :: :ok
  def ended(wardrik, id, name) do
    with {:ok, definition} <- Running.definition(wardrik, id),
         :ok <- removed(wardrik, id, name),
         :ok <- saved(wardrik, id, Map.put(definition, "triggers", without(definition, name))) do
      :ok
    else
      {:error, error} ->
        Logger.warning("#{id}'s trigger #{name} ran, and stays listed: #{error.message}")
    end
  end

  @doc "Passes a webhook request to the agent's trigger. The trigger checks the request first."
  @spec deliver(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def deliver(%Scope{wardrik: wardrik}, %{"agent" => id, "trigger" => name} = input) do
    request = %{
      body: input["body"],
      headers:
        Map.new(input["headers"], fn {header, value} -> {String.downcase(header), value} end),
      path_secret: input["secret"]
    }

    delivery = [agent_id: id, name: name, request: request]

    case Wardrik.Triggers.deliver(Wardrik.triggers(wardrik), delivery) do
      :ok ->
        {:ok, nil}

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "There's no trigger #{name} of #{id}.")}

      {:error, reason} ->
        {:error,
         Error.new(:unavailable, "#{id} can't be asked now (#{reason}); send it again later.")}
    end
  end

  # The next run reads in the trigger's zone, so whoever set it sees the time they meant.
  defp next(wardrik, id, trigger) do
    encoded = Trigger.encode(trigger)

    case Enum.find(Wardrik.Triggers.list(Wardrik.triggers(wardrik), id), fn {listed, _next_at} ->
           listed.name == trigger.name
         end) do
      {_listed, %DateTime{} = next_at} ->
        local =
          next_at
          |> DateTime.truncate(:second)
          |> DateTime.shift_zone!(trigger.timezone, Tz.TimeZoneDatabase)

        Map.put(encoded, "next_at", DateTime.to_iso8601(local))

      _unscheduled ->
        encoded
    end
  end

  defp set_trigger(wardrik, id, fields) do
    case Wardrik.Triggers.set(Wardrik.triggers(wardrik), id, fields) do
      {:ok, trigger} ->
        {:ok, trigger}

      {:error, why} when is_binary(why) ->
        {:error, Error.new(:invalid_request, "The trigger doesn't read: #{why}.")}

      {:error, reason} ->
        unsaved(id, reason)
    end
  end

  defp removed(wardrik, id, name) do
    case Wardrik.Triggers.remove(Wardrik.triggers(wardrik), agent_id: id, name: name) do
      :ok ->
        :ok

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "There's no trigger #{name} of #{id}.")}

      {:error, reason} ->
        unsaved(id, reason)
    end
  end

  defp saved(wardrik, id, definition) do
    case Definitions.put(wardrik, id, definition) do
      :ok -> :ok
      {:error, reason} -> unsaved(id, reason)
    end
  end

  defp unsaved(id, reason),
    do:
      {:error,
       Error.new(:unavailable, "#{id}'s triggers weren't saved: #{inspect(reason)}. Try again.")}

  defp kept(wardrik, id, name) do
    case Enum.find(Wardrik.Triggers.list(Wardrik.triggers(wardrik), id), fn {trigger, _next_at} ->
           trigger.name == name
         end) do
      {trigger, _next_at} -> {:ok, trigger}
      nil -> {:error, Error.new(:not_found, "There's no trigger #{name} of #{id}.")}
    end
  end

  defp replaced(definition, %{"name" => name} = fields) do
    triggers = Map.get(definition, "triggers", [])

    if Enum.any?(triggers, &(&1["name"] == name)),
      do: Enum.map(triggers, &if(&1["name"] == name, do: fields, else: &1)),
      else: triggers ++ [fields]
  end

  defp without(definition, name),
    do: definition |> Map.get("triggers", []) |> Enum.reject(&(&1["name"] == name))
end
