defmodule Wardrik.Connections.None do
  @moduledoc """
  The `Wardrik.Connections` of a host that offers none: each callback is
  `:unsupported`. A `Wardrik.Host` that names no `:connections` has it.
  """

  @behaviour Wardrik.Connections

  @impl Wardrik.Connections
  def list(_host, _owner), do: :unsupported

  @impl Wardrik.Connections
  def connect(_host, _provider, _owner, _by), do: :unsupported

  @impl Wardrik.Connections
  def disconnect(_host, _provider, _owner), do: :unsupported
end
