defmodule WardrikChannel.Install do
  @moduledoc """
  Adding the chat app to a workspace, for `owner`: where `c:WardrikChannel.install_url/2` sends
  them, and what `c:WardrikChannel.installed/2` finishes.

      %WardrikChannel.Install{owner: "acme", return_to: "/settings"}
      %WardrikChannel.Install{owner: "acme", query: conn.query_params}

  ## Fields

    * `:owner` - who it's added for, as your app names them, such as `acme`.
    * `:return_to` - where they're sent once it's added.
    * `:query` - the query string the chat app redirected back with.
  """

  @enforce_keys [:owner]
  defstruct [:owner, :return_to, query: %{}]

  @type t() :: %__MODULE__{owner: String.t(), return_to: String.t() | nil, query: map()}
end
