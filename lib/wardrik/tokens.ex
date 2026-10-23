defmodule Wardrik.Tokens do
  @moduledoc """
  The deployment's API tokens, which people and programs reach Wardrik over HTTP with.

      {:ok, %Wardrik.TokenIssued{secret: secret}} =
        Wardrik.Tokens.create(scope, name: "ci", roles: ["reader", "messenger"], resources: ["acme/agent/*"])

      {:ok, scope} = MyApp.Wardrik.authenticate(secret)
  """

  use Wardrik.Operations.Functions, prefix: "tokens"
end
