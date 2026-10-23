defmodule Wardrik.Tokens do
  @moduledoc """
  The deployment's API tokens, which people and programs reach Wardrik over HTTP with.

      {:ok, issued} = Wardrik.Tokens.create(scope, name: "ci", roles: ["reader"], resources: ["acme/agent/*"])
      #=> {:ok, %Wardrik.TokenIssued{token: %Wardrik.Token{id: "3f9a61c0d4e2", ...}, secret: "wrk_3f9a61c0d4e2_9c1e..."}}

      {:ok, ci} = MyApp.Wardrik.authenticate(issued.secret)
  """

  use Wardrik.Operations.Functions, prefix: "tokens"
end
