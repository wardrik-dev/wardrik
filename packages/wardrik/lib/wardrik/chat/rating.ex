defmodule Wardrik.Chat.Rating do
  @moduledoc """
  A member's rating of a run's answer. Adapters pass it to `Wardrik.Chat.rate/2` when a feedback
  button is pressed.

      %Wardrik.Chat.Rating{
        member: member,
        agent: "agt_01JF8X5RQ2",
        conversation: "slack.T0123.C024BE91L.1696.1234",
        run: "a1b2c3",
        rating: :positive
      }

    * `:member` - the `Wardrik.Chat.Member` who rated it.
    * `:agent`, `:conversation` and `:run` - from the button, as the reply's
      `Wardrik.Chat.Outbound` gave them. `:conversation` is `nil` for the agent's own.
    * `:rating` - `:positive` or `:negative`.
  """

  @enforce_keys [:member, :agent, :run, :rating]
  defstruct [:member, :agent, :conversation, :run, :rating]

  @type t() :: %__MODULE__{
          member: Wardrik.Chat.Member.t(),
          agent: String.t(),
          conversation: String.t() | nil,
          run: String.t(),
          rating: :positive | :negative
        }
end
