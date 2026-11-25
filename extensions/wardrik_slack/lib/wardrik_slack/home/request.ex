defmodule WardrikSlack.Home.Request do
  @moduledoc """
  The Home tab that `c:WardrikSlack.Home.blocks/2` fills.

    * `:workspace` - the Slack workspace it's opened in. Read as the member with
      `Wardrik.Chat.Workspace.member_scope/3`.
    * `:member` - the member who opened it.
  """

  @enforce_keys [:workspace, :member]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          workspace: Wardrik.Chat.Workspace.t(),
          member: Wardrik.Chat.Member.t()
        }
end
