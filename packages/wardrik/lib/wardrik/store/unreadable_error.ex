defmodule Wardrik.Store.UnreadableError do
  @moduledoc "Raised by a read where the scope's `Wardrik.Store.Format` can't read a value."

  defexception [:scope, :key, :reason]

  @type t() :: %__MODULE__{scope: String.t(), key: String.t(), reason: String.t()}

  @impl Exception
  def message(%__MODULE__{} = error),
    do: "#{error.scope}:#{error.key} can't be read: #{error.reason}"
end
