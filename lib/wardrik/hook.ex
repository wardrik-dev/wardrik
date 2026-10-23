defmodule Wardrik.Hook do
  @moduledoc """
  Delivers what services send to agents' webhook triggers, as the HTTP surface receives it.

      :ok = Wardrik.Hook.deliver(scope, "acme/triage", "issues", body: body, headers: headers)
  """

  use Wardrik.Operations.Functions, prefix: "hook"
end
