defmodule WardrikOAuth.Providers.None do
  @moduledoc "The `WardrikOAuth.Providers` of a deployment whose providers are the ones it configures."

  defstruct []

  @type t() :: %__MODULE__{}

  defimpl WardrikOAuth.Providers do
    def fetch(_providers, _name, _opts), do: :error
    def names(_providers), do: []
  end
end
