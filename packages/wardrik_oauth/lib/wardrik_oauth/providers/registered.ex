defmodule WardrikOAuth.Providers.Registered do
  @moduledoc """
  What people sign in to beyond an instance's own accounts, such as the
  servers they add, as its plugins list them among its host's `:sign_ins`.
  Each is read from the instance's host as a sign-in starts, renews or comes
  back, so it holds whatever order the plugins are listed in.

  `WardrikOAuth.attach/2` signs in to them on an instance.
  """

  @enforce_keys [:instance]
  defstruct [:instance]

  @type t() :: %__MODULE__{instance: module()}

  @doc false
  def sources(%__MODULE__{instance: instance}),
    do: instance |> Wardrik.Instance.host() |> Wardrik.Host.sign_ins() |> Map.values()
end

defimpl WardrikOAuth.Providers, for: WardrikOAuth.Providers.Registered do
  alias WardrikOAuth.Providers
  alias WardrikOAuth.Providers.Registered

  def fetch(registered, name, opts) do
    Enum.find_value(Registered.sources(registered), :error, fn source ->
      with :error <- Providers.fetch(source, name, opts), do: nil
    end)
  end

  def names(registered), do: Enum.flat_map(Registered.sources(registered), &Providers.names/1)
end
