defmodule Wardrik.NotifyTarget do
  @moduledoc """
  A place an owner's agents' notices go, never with its secret.

    * `:owner` - who keeps it, as your app names them, or `"deployment"`.
    * `:name` - what agents' definitions route to.
    * `:source` - `:config` for one the deployment starts with, `:runtime` for one added since.
    * `:kind` - what sends its notices, as `"webhook"`.
    * `:url` - where a webhook posts.
    * `:secret` - `%{"name" => name}`, the owner's secret that signs a webhook's notices.
  """

  use Wardrik.Type,
    schema: ["notify_target"],
    fields: [
      owner: "owner",
      name: "name",
      source: {"source", [:config, :runtime]},
      kind: "kind",
      url: "url",
      secret: "secret"
    ]
end
