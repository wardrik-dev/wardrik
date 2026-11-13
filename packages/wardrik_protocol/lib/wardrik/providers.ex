defmodule Wardrik.Providers do
  @moduledoc """
  Operations on the OAuth apps an owner keeps, for people to connect accounts with.

      Wardrik.Providers.add(scope, "acme", name: "linear", issuer: "https://linear.app")
      #=> {:ok, %Wardrik.OAuthApp{owner: "acme", name: "linear", ...}}

  A sign-in names one app by its owner and name. Using another owner's is `provider.use` on
  `{:provider, owner}`, as your authorizer decides.
  """

  use Wardrik.Operations.Functions, prefix: "providers"
end
