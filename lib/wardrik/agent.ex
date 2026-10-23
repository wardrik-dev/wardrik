defmodule Wardrik.Agent do
  @moduledoc """
  The operations on one agent, from asking it to deciding what it waits on.

      {:ok, %{"message" => message}} = Wardrik.Agent.ask(scope, "acme/triage", %{"content" => "What's on fire?"})
  """

  use Wardrik.Operations.Functions, prefix: "agent"
end
