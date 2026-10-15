defmodule WardrikMCP.Auth.None do
  @moduledoc "A server that takes no credential: its agents reach it as they are."

  defstruct []

  @type t() :: %__MODULE__{}

  defimpl WardrikMCP.Auth do
    def options(_none), do: []
    def name(_none), do: "none"
  end
end
