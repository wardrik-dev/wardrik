defmodule WardrikWeb.Page do
  @moduledoc """
  A page an extension adds to the dashboard: a LiveView at `<prefix>/x/<path>`, listed in the
  navigation as `label`.

      %WardrikWeb.Page{path: "fleet", label: "Fleet", live: MyApp.FleetLive}

  The page mounts like the dashboard's own, with `@scope` and `@dashboard` assigned.
  """

  @enforce_keys [:path, :label, :live]
  defstruct [:path, :label, :live]

  @type t() :: %__MODULE__{path: String.t(), label: String.t(), live: module()}
end
