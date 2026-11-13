defmodule Wardrik.Secrets do
  @moduledoc """
  Operations on an owner's secrets, sealed in Wardrik's vault. Values are never answered.

      Wardrik.Secrets.put(scope, owner: "acme", name: "CRM_KEY", value: "s3cret", purpose: "header")
      Wardrik.Secrets.list(scope, "acme")
      #=> {:ok, [%Wardrik.SealedSecret{name: "CRM_KEY", purpose: :header}]}

  The owner is a name your app gives, which Wardrik doesn't read. Your authorizer decides who may
  act for it, on the resource `{:secret, owner}`.
  """

  use Wardrik.Operations.Functions, prefix: "secrets"
end
