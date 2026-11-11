defmodule WardrikDaemon.Web.Pages do
  @moduledoc """
  The daemon's own pages in the dashboard: ceilings, tokens and the configuration. The
  dashboard's settings pages read the daemon's servers, secrets, notify targets, OAuth apps and
  connections. See `WardrikDaemon.Web.Router`.
  """
  use WardrikWeb.Extension

  alias WardrikWeb.Page

  @impl WardrikWeb.Extension
  def pages,
    do: [
      %Page{path: "ceilings", label: "Ceilings", live: WardrikDaemon.Web.CeilingsLive},
      %Page{path: "tokens", label: "Tokens", live: WardrikDaemon.Web.TokensLive},
      %Page{path: "config", label: "Configuration", live: WardrikDaemon.Web.ConfigLive}
    ]
end
