defmodule Wardrik.Operations.Triggers do
  @moduledoc "Operations on an agent's triggers: setting, removing, and delivering webhooks."

  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Running
  alias Wardrik.Scope
  alias WardrikTriggers.Trigger

  @doc "Sets one of the agent's triggers, and saves it in the agent's definition."
  @spec set(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def set(%Scope{wardrik: wardrik} = scope, %{"agent" => id, "trigger" => name} = input) do
    fields = input |> Map.drop(["agent", "trigger"]) |> Map.put("name", name)

    with :ok <- Running.definable(id),
         {:ok, definition} <- Running.definition(wardrik, id),
         :ok <- Wardrik.Resolution.trigger(wardrik, definition, fields, 1),
         {:ok, trigger} <- set_trigger(wardrik, id, fields),
         :ok <- saved(wardrik, id, Map.put(definition, "triggers", replaced(definition, fields))) do
      Changes.record(scope, "trigger.set", id, %{"trigger" => %{"name" => name}})
      {:ok, Trigger.encode(trigger)}
    end
  end

  @doc "Removes one of the agent's triggers. Returns the removed trigger."
  @spec remove(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def remove(%Scope{wardrik: wardrik} = scope, %{"agent" => id, "trigger" => name}) do
    with :ok <- Running.definable(id),
         {:ok, definition} <- Running.definition(wardrik, id),
         {:ok, trigger} <- kept(wardrik, id, name),
         :ok <- removed(wardrik, id, name),
         :ok <- saved(wardrik, id, Map.put(definition, "triggers", without(definition, name))) do
      Changes.record(scope, "trigger.removed", id, %{"trigger" => %{"name" => name}})
      {:ok, Trigger.encode(trigger)}
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

    case WardrikTriggers.deliver(Wardrik.triggers(wardrik), delivery) do
      :ok ->
        {:ok, nil}

      {:error, :not_found} ->
        {:error, Error.new(:not_found, "There's no trigger #{name} of #{id}.")}

      {:error, reason} ->
        {:error,
         Error.new(:unavailable, "#{id} can't be asked now (#{reason}); send it again later.")}
    end
  end

  defp set_trigger(wardrik, id, fields) do
    case WardrikTriggers.set(Wardrik.triggers(wardrik), id, fields) do
      {:ok, trigger} ->
        {:ok, trigger}

      {:error, why} when is_binary(why) ->
        {:error, Error.new(:invalid_request, "The trigger doesn't read: #{why}.")}

      {:error, reason} ->
        unsaved(id, reason)
    end
  end

  defp removed(wardrik, id, name) do
    case WardrikTriggers.remove(Wardrik.triggers(wardrik), agent_id: id, name: name) do
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
    case Enum.find(WardrikTriggers.list(Wardrik.triggers(wardrik), id), fn {trigger, _next_at} ->
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
