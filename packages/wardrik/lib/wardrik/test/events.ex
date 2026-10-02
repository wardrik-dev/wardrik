defmodule Wardrik.Test.Events do
  @moduledoc """
  Publishes events the way a turn would, so a test can drive a subscriber
  without running one.
  """

  alias Wardrik.Event
  alias Wardrik.Event.Source

  @doc "Publish `payload` on a fresh root span for `agent_id`."
  def emit(agent_id, payload), do: agent_id |> Source.root() |> Event.emit(payload)

  @doc "Publish `payload` on a child span, as work a turn spawned would."
  def emit_nested(agent_id, payload) do
    agent_id |> Source.root() |> Source.child() |> Event.emit(payload)
  end
end
