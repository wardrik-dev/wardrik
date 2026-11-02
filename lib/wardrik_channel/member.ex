defmodule WardrikChannel.Member do
  @moduledoc """
  Someone in a workspace: the chat app's `id` for them, and the `name` it shows.

  The channel's `WardrikChannel.Identities` says who they are in your app.
  """

  @enforce_keys [:id]
  defstruct [:id, :name]

  @type t() :: %__MODULE__{id: String.t(), name: String.t() | nil}
end
