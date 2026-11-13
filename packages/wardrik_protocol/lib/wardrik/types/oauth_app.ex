defmodule Wardrik.OAuthApp do
  @moduledoc """
  An OAuth app an owner keeps, never with its client secret.

    * `:owner` - who keeps it, as your app names them, or `"deployment"`.
    * `:name` - the account it grants.
    * `:source` - `:config` for one the deployment declares, `:runtime` for one added since.
    * `:issuer`, `:resource`, `:authorization_endpoint`, `:token_endpoint` - where it signs in.
    * `:client_id` - the service's client ID, or `nil` where Wardrik registers itself.
    * `:client_secret` - `%{"name" => name}`, the owner's secret that holds it.
    * `:scopes`, `:authorization_params`, `:client_auth`, `:flow` - how it signs in.
  """

  use Wardrik.Type,
    schema: ["provider"],
    fields: [
      owner: "owner",
      name: "name",
      source: {"source", [:config, :runtime]},
      issuer: "issuer",
      resource: "resource",
      authorization_endpoint: "authorization_endpoint",
      token_endpoint: "token_endpoint",
      client_id: "client_id",
      client_secret: "client_secret",
      scopes: "scopes",
      authorization_params: "authorization_params",
      client_auth: {"client_auth", [:post, :basic]},
      flow: {"flow", [:browser, :device]}
    ]
end
