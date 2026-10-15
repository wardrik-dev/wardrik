defmodule Wardrik.Servers.None do
  @moduledoc """
  The `Wardrik.Servers` of a host that lets nobody add servers: each
  function is `:unsupported`. A `Wardrik.Host` that names no `:servers` has
  it.
  """

  defstruct []

  @type t() :: %__MODULE__{}

  @doc "The error each operation answers where the host lets nobody add servers."
  @spec unsupported() :: Wardrik.Error.t()
  def unsupported, do: Wardrik.Error.new(:unsupported, "This server lets nobody add MCP servers.")
end

defimpl Wardrik.Servers, for: Wardrik.Servers.None do
  def list(_servers, _owner), do: :unsupported
  def add(_servers, _owner, _opts), do: :unsupported
  def remove(_servers, _owner, _opts), do: :unsupported
end
