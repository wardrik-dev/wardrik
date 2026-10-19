defmodule Wardrik.History.All do
  @moduledoc "A `Wardrik.History` that keeps every message, so an agent with it never compacts."

  defstruct []

  @type t() :: %__MODULE__{}

  defimpl Wardrik.History do
    def prepare(_all, _conversation, _opts), do: :keep
  end
end
