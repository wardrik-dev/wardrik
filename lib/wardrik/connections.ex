defmodule Wardrik.Connections do
  @moduledoc """
  The accounts an org or a person connects for their agents, by provider.

      {:ok, %Wardrik.Connecting{authorization: %Wardrik.Authorization{url: url}}} =
        Wardrik.Connections.connect(scope, "github", owner: "acme/@jon")
  """

  use Wardrik.Operations.Functions, prefix: "connections"
end
