defmodule WardrikWeb.Dashboard do
  @moduledoc """
  One mounted dashboard, as `WardrikWeb.Router.wardrik_dashboard/2` builds it.

  ## Fields

    * `:prefix` - the path it's mounted at.
    * `:resolver` - `{module, opts}`, the `WardrikWeb.Resolver` that gives each person's scope.
    * `:extensions` - the `WardrikWeb.Extension` modules it shows.
    * `:socket_path` - the path of the endpoint's LiveView socket.
    * `:sign_in` - where a person the resolver refuses is sent.
  """

  @enforce_keys [:prefix, :resolver]
  defstruct [:prefix, :resolver, extensions: [], socket_path: "/live", sign_in: "/"]

  @type t() :: %__MODULE__{
          prefix: String.t(),
          resolver: {module(), term()},
          extensions: [module()],
          socket_path: String.t(),
          sign_in: String.t()
        }

  @doc "Returns every extension's pages, in the order the extensions are given."
  @spec pages(t()) :: [WardrikWeb.Page.t()]
  def pages(%__MODULE__{extensions: extensions}), do: Enum.flat_map(extensions, & &1.pages())

  @doc "Returns the LiveComponents the extensions show in `slot`."
  @spec panels(t(), WardrikWeb.Extension.slot()) :: [module()]
  def panels(%__MODULE__{extensions: extensions}, slot),
    do: Enum.flat_map(extensions, & &1.panels(slot))
end
