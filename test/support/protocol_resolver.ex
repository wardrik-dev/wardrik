defmodule Tars.Test.ProtocolResolver do
  @moduledoc "Resolves the protocol's JSON Schemas by their `$id`, from `priv/protocol/v1`."

  use JSV.Resolver.Local, source: Application.app_dir(:tars, "priv/protocol/v1")
end
