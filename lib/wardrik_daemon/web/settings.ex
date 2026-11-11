defmodule WardrikDaemon.Web.Settings do
  @moduledoc false

  # Gives the dashboard's MCP servers, notify targets and OAuth apps pages the daemon's own:
  # what config.yaml sets, and what was added at runtime. The router passes each page's options:
  #
  #   * `:store` - `WardrikDaemon.Servers`, `WardrikDaemon.NotifyTargets` or `WardrikDaemon.OAuthApps`.
  #   * `:kind` and `:actions` - what the authorizer checks: `{read, add, delete}`.
  #   * `:schema` - the HTTP API's input schema for adding one.
  #   * `:columns` and `:common` - what the page shows.

  @behaviour WardrikWeb.Settings

  alias WardrikDaemon.Allowed
  alias WardrikDaemon.Owners
  alias WardrikDaemon.Web.Endpoint

  @impl true
  def owners(scope, _opts), do: choices(daemon(), scope)

  @doc "Returns the owners to choose from: the deployment's org, each org, the person, and the deployment."
  def choices(%{config: config}, scope) do
    person = if Owners.user?(scope.principal.id), do: [scope.principal.id], else: []
    Enum.uniq([config.org | Enum.sort(Map.keys(config.orgs))] ++ person ++ ["deployment"])
  end

  @impl true
  def list(scope, owner, opts) do
    daemon = daemon()
    {read, _add, _delete} = opts[:actions]

    with :ok <- Allowed.owned(daemon, scope, owner, {read, opts[:kind]}),
         do: {:ok, Enum.map(opts[:store].list(daemon, owner), &item/1)}
  end

  @impl true
  def columns(opts), do: opts[:columns]

  @impl true
  def schema(opts), do: WardrikDaemon.HTTP.schema(opts[:schema])

  @impl true
  def common(opts), do: opts[:common]

  @impl true
  def add(scope, owner, input, opts) do
    daemon = daemon()
    {_read, add, _delete} = opts[:actions]

    with {:ok, input} <- WardrikDaemon.HTTP.checked(opts[:schema], input),
         :ok <- Allowed.owned(daemon, scope, owner, {add, opts[:kind]}),
         {:ok, added} <- opts[:store].add(daemon, {owner, input}, scope.principal),
         do: {:ok, item(added)}
  end

  @impl true
  def remove(scope, owner, name, opts) do
    daemon = daemon()
    {_read, _add, delete} = opts[:actions]

    with :ok <- Allowed.owned(daemon, scope, owner, {delete, opts[:kind]}),
         {:ok, _removed} <- opts[:store].remove(daemon, {owner, name}, scope.principal),
         do: :ok
  end

  # A notify target names its signing secret as %{"name" => name}. Show the name.
  defp item(item) do
    item
    |> Map.new(fn
      {"secret", %{"name" => name}} -> {"secret", name}
      pair -> pair
    end)
    |> fixed()
  end

  defp fixed(%{"source" => "config"} = item), do: Map.put(item, "fixed", "Set in config.yaml")
  defp fixed(item), do: item

  @doc false
  def daemon, do: Endpoint.config(:daemon)
end
