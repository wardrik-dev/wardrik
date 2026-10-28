defmodule Wardrik.Operations.Triggers do
  @moduledoc """
  The operations on an agent's triggers: setting and removing one, and delivering what a service
  sends a webhook trigger.
  """

  alias Wardrik.Definitions
  alias Wardrik.Error
  alias Wardrik.Operations.Changes
  alias Wardrik.Operations.Running
  alias Wardrik.Scope
  alias WardrikTriggers.Trigger

  @doc "Sets one of the agent's triggers, and keeps it in its definition."
  @spec set(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def set(%Scope{wardrik: wardrik} = scope, %{"agent" => id, "trigger" => name} = input) do
    fields = input |> Map.drop(["agent", "trigger"]) |> Map.put("name", name)

    with :ok <- Running.definable(id),
         {:ok, definition} <- Running.definition(wardrik, id),
         :ok <- Wardrik.Resolution.trigger(wardrik, definition, fields, 1),
         {:ok, trigger} <- set_trigger(wardrik, id, fields),
         :ok <-
           Definitions.put(
             wardrik,
             id,
             Map.put(definition, "triggers", replaced(definition, fields))
           ) do
      Changes.record(scope, "trigger.set", id, %{"trigger" => %{"name" => name}})
      {:ok, Trigger.encode(trigger)}
    end
  end

  @doc "Removes one of the agent's triggers, and answers it as it was."
  @spec remove(Scope.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def remove(%Scope{wardrik: wardrik} = scope, %{"agent" => id, "trigger" => name}) do
    with :ok <- Running.definable(id),
         {:ok, definition} <- Running.definition(wardrik, id),
         {:ok, trigger} <- kept(wardrik, id, name),
         :ok <- WardrikTriggers.remove(Wardrik.triggers(wardrik), id, name),
         :ok <-
           Definitions.put(
             wardrik,
             id,
             Map.put(definition, "triggers", without(definition, name))
           ) do
      Changes.record(scope, "trigger.removed", id, %{"trigger" => %{"name" => name}})
      {:ok, Trigger.encode(trigger)}
    end
  end

  @doc "Asks the agent about a request a service sent its webhook trigger, once it proves itself."
  @spec deliver(Scope.t(), map()) :: {:ok, nil} | {:error, Error.t()}
  def deliver(%Scope{wardrik: wardrik}, %{"agent" => id, "trigger" => name} = input) do
    request = %{
      body: input["body"],
      headers:
        Map.new(input["headers"], fn {header, value} -> {String.downcase(header), value} end),
      path_secret: input["secret"]
    }

    case WardrikTriggers.deliver(Wardrik.triggers(wardrik), id, name, request) do
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
      {:ok, trigger} -> {:ok, trigger}
      {:error, why} -> {:error, Error.new(:invalid_request, "The trigger doesn't read: #{why}.")}
    end
  end

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
