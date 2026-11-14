defmodule Wardrik.Store.Format.JSON do
  @moduledoc """
  Keeps JSON as it's given, at version 1. A scope's format unless it names one.

  When a kind's shape changes, give it a `Wardrik.Format` of its own whose `load(1, json)`
  reads what this one wrote.
  """

  @behaviour Wardrik.Format

  @impl Wardrik.Format
  def version, do: 1

  @impl Wardrik.Format
  def dump(json), do: json

  @impl Wardrik.Format
  def load(1, json), do: {:ok, json}
end
