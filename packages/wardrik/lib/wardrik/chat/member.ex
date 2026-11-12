defmodule Wardrik.Chat.Member do
  @moduledoc """
  Someone in a workspace: the chat app's `id` for them, the `name` it shows, and the `email`
  address it holds for them, if it gave one.

  The channel's `Wardrik.Chat.Identities` says who they are in your app.
  """

  @enforce_keys [:id]
  defstruct [:id, :name, :email]

  @type t() :: %__MODULE__{id: String.t(), name: String.t() | nil, email: String.t() | nil}
end
