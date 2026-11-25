defmodule Wardrik.Chat.Prompts.Request do
  @moduledoc """
  The conversation `c:Wardrik.Chat.Prompts.suggest/2` suggests prompts for.

      %Wardrik.Chat.Prompts.Request{channel: "slack", workspace: "T0123", member: "U024BE7LH"}

    * `:channel` - the channel's name.
    * `:workspace` - the workspace's ID in the chat app.
    * `:member` - the ID in the chat app of the member who started it.
  """

  @enforce_keys [:channel, :workspace, :member]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{channel: String.t(), workspace: String.t(), member: String.t()}
end
