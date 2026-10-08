defmodule Wardrik.Test.EventLog do
  @moduledoc "Reads and tampers with agents' `Wardrik.Event.Log`s."

  alias Wardrik.Event.Log

  @doc "The CloudEvent types in an agent's log, oldest first."
  def types(agent_id) do
    {:ok, events} = Log.read(agent_id)
    Enum.map(events, & &1["type"])
  end

  @doc """
  Writes an event into an agent's log at the first number free, as an owner
  that had taken over would, so the agent's next write finds it replaced.
  """
  def usurp(agent_id), do: usurp(agent_id, Log.oldest(agent_id))

  defp usurp(agent_id, sequence) do
    event = %{"id" => "usurper", "type" => "wardrik.agent.started"}

    case WardrikStore.put(Log.namespace(), Log.key(agent_id, sequence), event, if_vsn: nil) do
      {:ok, _vsn} -> :ok
      {:error, :conflict} -> usurp(agent_id, sequence + 1)
    end
  end
end
