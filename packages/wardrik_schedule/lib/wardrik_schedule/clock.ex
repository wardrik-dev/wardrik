defmodule WardrikSchedule.Clock do
  @moduledoc """
  The source of a schedule that names none: every run finds one item, which
  holds nothing to show, so the agent is asked its prompt alone each time.
  """

  @behaviour WardrikSchedule.Source

  alias WardrikSchedule.Item

  @impl WardrikSchedule.Source
  def decode(fields) when map_size(fields) == 0, do: {:ok, nil}

  @impl WardrikSchedule.Source
  def encode(nil), do: %{}

  @impl WardrikSchedule.Source
  def check(nil, cursor, _agent),
    do: {:ok, [%Item{id: DateTime.to_iso8601(DateTime.utc_now())}], cursor}
end
