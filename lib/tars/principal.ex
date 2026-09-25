defmodule Tars.Principal do
  @moduledoc """
  Who did something, and how they were known: the person or system behind a
  decision.

      %Tars.Principal{type: :slack, id: "U024BE7LH", name: "jon"}

  `type` says how they reached Tars:

    * `:shell` - an operating system account on the node, through `bin/tars`
    * `:ssh` - an SSH session to the TUI, by the name the client connected as
    * `:terminal` - a TUI started in a terminal on the node
    * `:slack` - a Slack user, by their user id
    * `:oauth` - the user an authorization flow finished for
    * `:token` - a caller of the HTTP API, by the id of the token it presented
  """

  @enforce_keys [:type, :id]
  defstruct [:type, :id, :name]

  @type t() :: %__MODULE__{
          type: :shell | :ssh | :terminal | :slack | :oauth | :token | atom(),
          id: String.t(),
          name: String.t() | nil
        }
end
