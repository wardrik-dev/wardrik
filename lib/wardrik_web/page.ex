defmodule WardrikWeb.Page do
  @moduledoc """
  A page that an extension adds to the dashboard.

  The dashboard serves the LiveView `live` at `<prefix>/x/<path>`. The navigation links to it
  with the text `label`.

      %WardrikWeb.Page{path: "fleet", label: "Fleet", live: MyApp.FleetLive}

  The page gets `@scope` and `@dashboard`, like the dashboard's own pages.
  """

  @enforce_keys [:path, :label, :live]
  defstruct [:path, :label, :live]

  @type t() :: %__MODULE__{path: String.t(), label: String.t(), live: module()}
end
