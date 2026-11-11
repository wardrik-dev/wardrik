defmodule WardrikWeb.Page do
  @moduledoc """
  A page that an extension adds to the dashboard.

  The dashboard serves the LiveView `live` at `<prefix>/x/<path>`. The navigation links to it
  with the text `label`.

      %WardrikWeb.Page{path: "fleet", label: "Fleet", live: MyApp.FleetLive}

  ## Writing a page

  `use WardrikWeb.Page` makes a LiveView with the dashboard's components imported and
  `WardrikWeb.Form` aliased:

      defmodule MyApp.FleetLive do
        use WardrikWeb.Page

        @impl true
        def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Fleet")}

        @impl true
        def render(assigns) do
          ~H\"""
          <.head title="Fleet" lead="Runs and cost for each agent." />
          <div class="card">
            <header>Teams</header>
            <div class="body">...</div>
          </div>
          \"""
        end
      end

  The page gets `@scope` and `@dashboard`, like the dashboard's own pages. Run operations with
  `Wardrik.Scope.run(@scope, id, input)`.

  These classes match the dashboard's look:

    * `card`, with a `header` and a `body`.
    * `list` on a table. Add `stack` to stack the cells on narrow screens, and set `data-label`
      on each cell.
    * `btn`, `btn primary`, `btn small` and `btn danger` on buttons.
    * `flash error` and `flash info` on messages, and `empty` for an empty list.
  """

  @enforce_keys [:path, :label, :live]
  defstruct [:path, :label, :live]

  @type t() :: %__MODULE__{path: String.t(), label: String.t(), live: module()}

  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveView

      import WardrikWeb.Components

      alias WardrikWeb.Form
    end
  end
end
