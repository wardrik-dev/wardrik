defmodule Wardrik.Test.Audit do
  @moduledoc "Reads what `Wardrik.Audit` recorded, for tests of the surfaces that record it."

  alias Wardrik.Event.Log

  @doc "Every change the audit log holds, as CloudEvents, oldest first."
  @spec all() :: [map()]
  def all do
    (Log.oldest(:audit) - 1)
    |> Stream.unfold(fn after_sequence ->
      case Log.read(:audit, starting_after: after_sequence) do
        {:ok, []} -> nil
        {:ok, events} -> {events, after_sequence + length(events)}
      end
    end)
    |> Enum.concat()
  end

  @doc """
  The changes recorded about `subject`, such as `"agents/acme/triage"`, as
  `{type, actor}`: the CloudEvent type without `wardrik.`, and the actor's
  data, or `nil`. Oldest first.
  """
  @spec about(String.t()) :: [{String.t(), map() | nil}]
  def about(subject) do
    for %{"subject" => ^subject, "type" => "wardrik." <> type} = event <- all(),
        do: {type, event["data"]["actor"]}
  end
end
