defmodule WardrikCore.Events do
  @moduledoc """
  Where an agent's events go, such as a log or a broadcast.

      defmodule MyApp.Events do
        @behaviour WardrikCore.Events

        @impl true
        def handle_event(%WardrikCore.Event{} = event, _opts) do
          Phoenix.PubSub.broadcast(MyApp.PubSub, "agent:\#{event.metadata.agent_id}", event)
        end
      end

  Give it to an agent as `events: {MyApp.Events, opts}`. It runs in the agent's process, so return
  quickly.
  """

  @doc "Handles one event. The return value is ignored."
  @callback handle_event(WardrikCore.Event.t(), opts :: term()) :: any()
end
