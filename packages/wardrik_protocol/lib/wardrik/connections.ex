defmodule Wardrik.Connections do
  @moduledoc """
  Operations on the caller's own connected accounts: each OAuth app they may sign in with.

      Wardrik.Connections.connect(scope, "linear")
      #=> {:ok, %Wardrik.Connecting{provider: "linear", connected: false, authorization: %{"url" => "..."}}}

  Authorized on `{:connection, principal_id}`, the caller's own.
  """

  use Wardrik.Operations.Functions, prefix: "connections"
end
