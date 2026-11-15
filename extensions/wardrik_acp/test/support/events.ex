defmodule WardrikACP.TestEvents do
  @moduledoc "Sends each event of a call to the test process given as its options."
  @behaviour WardrikCore.Events

  @impl WardrikCore.Events
  def handle_event(event, test), do: send(test, {:event, event})
end
