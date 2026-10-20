defmodule Wardrik.Test.Events do
  @moduledoc """
  Publishes events the way a turn would, so a test can drive a subscriber
  without running one.
  """

  alias Wardrik.Bus
  alias Wardrik.Bus.Source

  @doc "Publish `payload` on a fresh root span for `agent_id`."
  def emit(agent_id, payload), do: agent_id |> Source.root() |> Bus.Event.emit(payload)

  @doc "Publish `payload` on a child span, as work a turn spawned would."
  def emit_nested(agent_id, payload) do
    agent_id |> Source.root() |> Source.child() |> Bus.Event.emit(payload)
  end
end
