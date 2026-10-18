defmodule WardrikTrigger.Clock do
  @moduledoc """
  The source of a trigger that names none: every run finds one item, which
  holds nothing to show, so the agent is asked its prompt alone each time.
  """

  @behaviour WardrikTrigger.Source

  alias WardrikTrigger.Item

  @impl WardrikTrigger.Source
  def decode(fields) when map_size(fields) == 0, do: {:ok, nil}

  @impl WardrikTrigger.Source
  def encode(nil), do: %{}

  @impl WardrikTrigger.Source
  def check(nil, cursor, _opts),
    do: {:ok, [%Item{id: DateTime.to_iso8601(DateTime.utc_now())}], cursor}
end
