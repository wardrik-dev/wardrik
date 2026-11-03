defmodule Wardrik.Views do
  @moduledoc false

  @doc "Returns `event` as the protocol's JSON, which the views fold."
  @spec json(Wardrik.Event.t() | map()) :: map()
  def json(%Wardrik.Event{} = event), do: Wardrik.Event.to_json(event)
  def json(event), do: event
end
