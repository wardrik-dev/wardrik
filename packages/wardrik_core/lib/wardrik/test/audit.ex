defmodule Wardrik.Test.Audit do
  @moduledoc "Reads what `Wardrik.Audit` recorded, for tests of the surfaces that record it."

  alias Wardrik.Event.Log

  @doc "Every change the audit log in `store` holds, as CloudEvents, oldest first."
  @spec all(WardrikStore.t()) :: [map()]
  def all(store \\ Wardrik.Test.store()) do
    (Log.oldest(store, :audit) - 1)
    |> Stream.unfold(fn after_sequence ->
      case Log.read(store, :audit, starting_after: after_sequence) do
        {:ok, []} -> nil
        {:ok, events} -> {events, after_sequence + length(events)}
      end
    end)
    |> Enum.concat()
  end

  @doc """
  The changes recorded about `subject`, an agent, or a resource or its
  name, such as `"acme/agent/triage"`, as `{type, actor}`: the CloudEvent
  type without `wardrik.`, and the actor's data, or `nil`. Oldest first.
  """
  @spec about(Wardrik.AgentID.t() | Wardrik.Resource.t() | String.t()) ::
          [{String.t(), map() | nil}]
  def about(%Wardrik.AgentID{} = id), do: about(Wardrik.AgentID.resource(id))

  def about(subject) do
    subject = to_string(subject)

    for %{"subject" => ^subject, "type" => "wardrik." <> type} = event <- all(),
        do: {type, event["data"]["actor"]}
  end
end
