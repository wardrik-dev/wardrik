defmodule Wardrik.Chat.Answer do
  @moduledoc """
  A member's answer to a call the agent waits on. Adapters pass it to `Wardrik.Chat.decide/2`
  when a button is pressed.

      %Wardrik.Chat.Answer{
        member: member,
        agent: "agt_01JF8X5RQ2",
        conversation: "slack.T0123.C024BE91L.1696.1234",
        interrupt: "int_1",
        decision: {:approve, "Looks fine."}
      }

    * `:member` - the `Wardrik.Chat.Member` who answered.
    * `:agent` - the agent's ID, from the `Wardrik.Chat.Waiting` on the button.
    * `:conversation` - the conversation's ID, from the same. `nil` for the agent's own.
    * `:interrupt` - the interrupt's ID.
    * `:asked_by` - the ID of who asked for the turn. Optional.
    * `:decision` - `{:approve, note}` or `{:deny, reason}`. Either may be `nil`.
  """

  @enforce_keys [:member, :agent, :interrupt, :decision]
  defstruct [:member, :agent, :conversation, :interrupt, :asked_by, :decision]

  @type t() :: %__MODULE__{
          member: Wardrik.Chat.Member.t(),
          agent: String.t(),
          conversation: String.t() | nil,
          interrupt: String.t(),
          asked_by: String.t() | nil,
          decision: {:approve | :deny, String.t() | nil}
        }
end
