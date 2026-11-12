defmodule WardrikWeb.Extension do
  @moduledoc """
  An extension adds pages and panels to the dashboard.

  A page is a LiveView with its own link in the navigation. A panel is a LiveComponent shown on
  an existing page.

  List your extensions in `WardrikWeb.Router.wardrik_dashboard/2`:

      wardrik_dashboard "/wardrik",
        resolver: {MyAppWeb.WardrikResolver, []},
        extensions: [MyAppWeb.DashboardExtension]

  An extension looks like this:

      defmodule MyAppWeb.DashboardExtension do
        use WardrikWeb.Extension

        @impl WardrikWeb.Extension
        def pages, do: [%WardrikWeb.Page{path: "fleet", label: "Fleet", live: MyApp.FleetLive}]

        @impl WardrikWeb.Extension
        def panels(:agents), do: [MyApp.BulkActions]
        def panels(_slot), do: []
      end

  Every panel gets `@scope` and `@dashboard`. Each slot also passes these assigns:

  | Slot | Where the panel is shown | Assigns |
  | --- | --- | --- |
  | `:agents` | Above the agents list | `@agents`: the result of `agents.list` |
  | `:agent` | Next to an agent's timeline | `@agent`: the agent ID. `@conversation`: the conversation ID. `@read`: the result of `agent.read` |
  """

  @typedoc "Where a panel is shown."
  @type slot() :: :agents | :agent

  @doc "Returns the pages the extension adds. Defaults to `[]`."
  @callback pages() :: [WardrikWeb.Page.t()]

  @doc "Returns the panels the extension adds to `slot`. Defaults to `[]`."
  @callback panels(slot()) :: [module()]

  defmacro __using__(_opts) do
    quote do
      @behaviour WardrikWeb.Extension

      @impl WardrikWeb.Extension
      def pages, do: []

      @impl WardrikWeb.Extension
      def panels(_slot), do: []

      defoverridable pages: 0, panels: 1
    end
  end
end
