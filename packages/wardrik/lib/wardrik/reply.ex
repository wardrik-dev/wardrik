defmodule Wardrik.Reply do
  @moduledoc """
  What an agent answered, when you asked it with `wait:`.

      {:ok, %Wardrik.Reply{text: text}} =
        Wardrik.agent_ask(scope, agent, "Where is order 1001?", wait: :timer.seconds(30))

  `text` is what the agent said: the text of each of its messages, joined.
  `messages` are the messages its run added, tool calls and their results
  included, as its log has them. `run` is the run's id. `cursor` is where
  the agent's log stands after the run, for `Wardrik.events/2` to read on
  from.
  """

  @enforce_keys [:agent, :run, :text, :messages, :cursor]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          agent: Wardrik.AgentAddress.t(),
          run: String.t(),
          text: String.t(),
          messages: [map()],
          cursor: String.t()
        }
end
