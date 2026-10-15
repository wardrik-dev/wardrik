defmodule WardrikMCP.Auth.None do
  @moduledoc "A server that takes no credential: its agents reach it as they are."

  defstruct []

  @type t() :: %__MODULE__{}

  defimpl WardrikMCP.Auth do
    def options(_none, _key), do: []
    def name(_none), do: "none"
    def provider(_none, _key, _url), do: :none
  end
end
