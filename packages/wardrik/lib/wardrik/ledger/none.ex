defmodule Wardrik.Ledger.None do
  @moduledoc """
  The `Wardrik.Ledger` of a scope that names none: every claim is `:ok`,
  nothing is recorded, and no entry is ever found. A turn under it that runs
  twice does its work twice.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl Wardrik.Ledger, for: Wardrik.Ledger.None do
  def claim(_ledger, _key, _opts), do: :ok
  def settle(_ledger, _key, _opts), do: :ok
  def fetch(_ledger, _key, _opts), do: :error
  def release(_ledger, _key, _opts), do: :ok
  def forget(_ledger, _agent_id, _opts), do: :ok
end
