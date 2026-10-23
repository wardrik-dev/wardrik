defmodule Wardrik.Connections do
  @moduledoc """
  The accounts an org or a person connects for their agents, by provider.

      Wardrik.Connections.connect(scope, "github", owner: "acme/@jon")
      #=> {:ok, %Wardrik.Connecting{provider: "github", connected: false, authorization: %Wardrik.Authorization{...}}}
  """

  use Wardrik.Operations.Functions, prefix: "connections"
end
