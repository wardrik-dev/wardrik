defmodule Wardrik.Test.ProtocolResolver do
  @moduledoc "Resolves the protocol's JSON Schemas by their `$id`, from `priv/protocol/v1`."

  use JSV.Resolver.Local, source: Application.app_dir(:wardrik, "priv/protocol/v1")
end
