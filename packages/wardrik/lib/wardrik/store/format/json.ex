defmodule Wardrik.Store.Format.JSON do
  @moduledoc """
  Keeps JSON as it's given, at version 1. A scope's format unless it names one.

  When a kind's shape changes, give it a `WardrikCore.Format` of its own whose `load(1, json)`
  reads what this one wrote.
  """

  @behaviour WardrikCore.Format

  @impl WardrikCore.Format
  def version, do: 1

  @impl WardrikCore.Format
  def dump(json), do: json

  @impl WardrikCore.Format
  def load(1, json), do: {:ok, json}
end
