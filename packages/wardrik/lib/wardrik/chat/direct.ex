defmodule Wardrik.Chat.Direct do
  @moduledoc """
  Says which agent answers a member's direct messages. A channel without one doesn't answer them.

      slack: {WardrikSlack, ..., direct: {MyApp.Assistants, []}}

      defmodule MyApp.Assistants do
        @behaviour Wardrik.Chat.Direct

        @impl true
        def agent(%Wardrik.Chat.Direct.Request{principal: principal}, _opts) do
          case MyApp.Assistants.for(principal.id) do
            %MyApp.Assistant{agent_id: id} -> {:ok, id}
            nil -> {:error, "You have no assistant yet."}
          end
        end
      end

    * The agent answers every direct message, in a thread of its own, as it does in a room.
    * The agent must list the channel in its definition's `channels`.
    * A member you return an error for is told the error.
  """

  alias Wardrik.Chat.Direct.Request

  @doc "Returns the ID of the agent that answers the request's member, or what to tell them."
  @callback agent(Request.t(), opts :: term()) :: {:ok, String.t()} | {:error, String.t()}
end
