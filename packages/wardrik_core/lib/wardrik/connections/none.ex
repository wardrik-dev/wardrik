defmodule Wardrik.Connections.None do
  @moduledoc """
  The `Wardrik.Connections` of a host that offers none: each function is
  `:unsupported`. A `Wardrik.Host` that names no `:connections` has it.
  """

  defstruct []

  @type t() :: %__MODULE__{}

  @doc "The error each operation answers where the host offers no connections."
  @spec unsupported() :: Wardrik.Error.t()
  def unsupported, do: Wardrik.Error.new(:unsupported, "This server offers no connections.")
end

defimpl Wardrik.Connections, for: Wardrik.Connections.None do
  def list(_connections, _owner), do: :unsupported
  def connect(_connections, _provider, _owner, _opts), do: :unsupported
  def disconnect(_connections, _provider, _owner), do: :unsupported
end
