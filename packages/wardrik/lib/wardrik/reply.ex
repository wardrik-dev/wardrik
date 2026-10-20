defmodule Wardrik.Reply do
  @moduledoc """
  What an agent answered: the end of the turn `ask` waited for, or `await`.

      maria = %MyApp.Accounts.User{org: "acme", id: 42, email: "maria@acme.example"}

      {:ok, %Wardrik.Reply{text: text}} = MyApp.Agents.ask(maria, "support", "Where is order 1001?")

  `send` answers at once, so a slow turn need not hold the caller; `await`
  takes its message later:

      {:ok, message} = MyApp.Agents.send(maria, "support", "Summarise last month's orders")

      {:ok, %Wardrik.Reply{text: summary}} =
        MyApp.Agents.await(maria, message, timeout: :timer.minutes(5))

  `text` is what the agent said: the text of each of its messages, joined.
  `messages` are the messages its run added, tool calls and their results
  included, as its log has them. `run` is the run's id. `cursor` is where
  the agent's log stands after the run, for `events` to read on from.
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
