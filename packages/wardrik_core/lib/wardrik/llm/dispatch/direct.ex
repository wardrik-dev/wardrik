defmodule Wardrik.LLM.Dispatch.Direct do
  @moduledoc """
  The `Wardrik.LLM.Dispatch` of a host that names none: each request is made
  as it stands, with the model its config names and the key the host's
  credentials or the environment supply, and nothing is told how it went.
  """

  defstruct []

  @type t() :: %__MODULE__{}
end

defimpl Wardrik.LLM.Dispatch, for: Wardrik.LLM.Dispatch.Direct do
  def admit(_direct, request, _opts), do: {:ok, request}
  def settle(_direct, _request, _opts), do: :ok
end
