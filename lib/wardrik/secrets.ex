defmodule Wardrik.Secrets do
  @moduledoc """
  The operations on an owner's secrets: sealing one, listing them by name, and removing one.

      Wardrik.Secrets.put(scope, "GITHUB_TOKEN", owner: "acme", value: "ghp_...")
      #=> :ok

      Wardrik.Secrets.list(scope, owner: "acme")
      #=> {:ok, [%Wardrik.Secret{name: "GITHUB_TOKEN", kind: :secret}]}

  The owner `deployment` is the deployment's own, which `${NAME}` in a daemon's config reads, and
  no agent reaches.
  """

  use Wardrik.Operations.Functions, prefix: "secrets"
end
