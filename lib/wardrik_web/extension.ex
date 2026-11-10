defmodule WardrikWeb.Extension do
  @moduledoc """
  Adds pages and panels to the dashboard. Pass extensions to
  `WardrikWeb.Router.wardrik_dashboard/2` as `extensions: [MyExtension]`.

      defmodule MyApp.DashboardExtension do
        use WardrikWeb.Extension

        @impl WardrikWeb.Extension
        def pages, do: [%WardrikWeb.Page{path: "fleet", label: "Fleet", live: MyApp.FleetLive}]

        @impl WardrikWeb.Extension
        def panels(:agents), do: [MyApp.BulkActions]
        def panels(_slot), do: []
      end

  A panel is a `Phoenix.LiveComponent`. Each slot gives it these assigns, with `@scope` and
  `@dashboard`:

  | Slot | Where | Assigns |
  | --- | --- | --- |
  | `:agents` | above the agents list | `@agents`, as `agents.list` answers them |
  | `:agent` | beside an agent's timeline | `@agent` and `@conversation`, its IDs, and `@read`, as `agent.read` answers |
  """

  @typedoc "Where a panel shows."
  @type slot() :: :agents | :agent

  @doc "Returns the pages it adds. `[]` unless defined."
  @callback pages() :: [WardrikWeb.Page.t()]

  @doc "Returns the LiveComponents it shows in `slot`. `[]` unless defined."
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
