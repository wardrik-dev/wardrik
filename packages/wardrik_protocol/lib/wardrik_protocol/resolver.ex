defmodule WardrikProtocol.Resolver do
  @moduledoc """
  Resolves the protocol's schemas by their `$id`, for `JSV.build!/2`. The
  schemas are read into this module when it compiles.
  """

  use JSV.Resolver.Local, source: Application.app_dir(:wardrik_protocol, "priv/v1")
end
