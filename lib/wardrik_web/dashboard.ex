defmodule WardrikWeb.Dashboard do
  @moduledoc """
  The settings of one mounted dashboard.

  `WardrikWeb.Router.wardrik_dashboard/2` creates it. Every page gets it as `@dashboard`.

  ## Fields

    * `:prefix` - the path the dashboard is mounted at.
    * `:resolver` - `{module, opts}`, the `WardrikWeb.Resolver` that returns each person's scope.
    * `:extensions` - the `WardrikWeb.Extension` modules that add pages and panels.
    * `:settings` - the settings pages that are on, as `{module, opts}` by page.
    * `:socket_path` - the path of the endpoint's LiveView socket.
    * `:sign_in` - where to redirect people the resolver refuses.
  """

  @enforce_keys [:prefix, :resolver]
  defstruct [
    :prefix,
    :resolver,
    extensions: [],
    settings: %{},
    socket_path: "/live",
    sign_in: "/"
  ]

  @type t() :: %__MODULE__{
          prefix: String.t(),
          resolver: {module(), term()},
          extensions: [module()],
          settings: %{optional(atom()) => {module(), term()}},
          socket_path: String.t(),
          sign_in: String.t()
        }

  @doc "Returns the pages that the extensions add."
  @spec pages(t()) :: [WardrikWeb.Page.t()]
  def pages(%__MODULE__{extensions: extensions}), do: Enum.flat_map(extensions, & &1.pages())

  @doc "Returns the panels (LiveComponents) that the extensions add to `slot`."
  @spec panels(t(), WardrikWeb.Extension.slot()) :: [module()]
  def panels(%__MODULE__{extensions: extensions}, slot),
    do: Enum.flat_map(extensions, & &1.panels(slot))
end
