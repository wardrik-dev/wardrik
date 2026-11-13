defmodule WardrikDaemon.Web.Settings do
  @moduledoc false

  # Gives the dashboard's MCP servers, notify targets and OAuth apps pages the daemon's own,
  # through WardrikDaemon.Settings. The router passes each page's options:
  #
  #   * `:kind` - `servers`, `notify_targets` or `oauth_apps`.
  #   * `:columns` and `:common` - what the page shows.

  @behaviour WardrikWeb.Settings

  alias WardrikDaemon.Settings
  alias WardrikDaemon.Web.Endpoint

  @impl true
  def owners(scope, _opts), do: Settings.owners(daemon(), scope)

  @impl true
  def list(scope, owner, opts) do
    with {:ok, items} <- Settings.list(daemon(), scope, opts[:kind], owner),
         do: {:ok, Enum.map(items, &fixed/1)}
  end

  @impl true
  def columns(opts), do: opts[:columns]

  @impl true
  def schema(opts), do: Settings.input(opts[:kind])

  @impl true
  def common(opts), do: opts[:common]

  @impl true
  def add(scope, owner, input, opts) do
    with {:ok, added} <- Settings.add(daemon(), scope, opts[:kind], owner, input),
         do: {:ok, fixed(added)}
  end

  @impl true
  def remove(scope, owner, name, opts),
    do: Settings.remove(daemon(), scope, opts[:kind], owner, name)

  defp fixed(%{"source" => "config"} = item), do: Map.put(item, "fixed", "Set in config.yaml")
  defp fixed(item), do: item

  @doc false
  @spec daemon() :: map()
  def daemon, do: Endpoint.config(:daemon)
end
