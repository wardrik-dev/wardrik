defmodule WardrikDaemon.Settings do
  @moduledoc """
  Lists, adds and removes an owner's MCP servers, notify targets and OAuth apps: what
  `config.yaml` sets, and what was added at runtime. The dashboard's settings pages and the
  `settings` tools use it. See `WardrikDaemon.SettingsTools`.

  | Kind | Store | Checked as |
  | --- | --- | --- |
  | `servers` | Wardrik's `servers.*` | `mcp_server` |
  | `notify_targets` | Wardrik's `notify_targets.*` | `notify_target` |
  | `oauth_apps` | Wardrik's `providers.*` | `provider` |

  Each checks `read`, `add` or `delete` on the owner's kind, as the HTTP API does. Those that are
  Wardrik's operations run as the scope.
  """

  alias Wardrik.Error
  alias WardrikDaemon.Allowed
  alias WardrikDaemon.Owners

  @kinds %{
    "servers" => %{operation: "servers", kind: :mcp_server, input: "server_input"},
    "notify_targets" => %{
      operation: "notify_targets",
      listed: "targets",
      kind: :notify_target,
      input: "notify_target_input"
    },
    "oauth_apps" => %{operation: "providers", kind: :provider, input: "provider_input"}
  }

  @typedoc "The Wardrik's `:wardrik` name, the daemon's `:store`, and `:config`."
  @type daemon() :: %{
          required(:wardrik) => atom(),
          required(:store) => Wardrik.Store.t(),
          required(:config) => WardrikDaemon.Config.t(),
          optional(atom()) => term()
        }

  @typedoc "One of `servers`, `notify_targets` or `oauth_apps`."
  @type kind() :: String.t()

  @doc "Returns the kinds, in the order the dashboard shows them."
  @spec kinds() :: [kind()]
  def kinds, do: ~w(servers notify_targets oauth_apps)

  @doc "Returns the JSON Schema of the input that adds one of `kind`."
  @spec input(kind()) :: map()
  def input(kind) do
    case @kinds[kind] do
      %{operation: _operation, input: input} -> WardrikProtocol.schema(input)
      %{input: input} -> WardrikDaemon.HTTP.schema(input)
    end
  end

  @doc "Returns the owners `scope` may choose from: the deployment's org, each org, the person, and the deployment."
  @spec owners(map(), Wardrik.Scope.t()) :: [String.t()]
  def owners(%{config: config}, scope) do
    person = if Owners.user?(scope.principal.id), do: [scope.principal.id], else: []
    Enum.uniq([config.org | Enum.sort(Map.keys(config.orgs))] ++ person ++ ["deployment"])
  end

  @doc """
  Lists the owner's settings of `kind`. A notify target's signing secret is listed by name, and
  each one `config.yaml` sets has `"source" => "config"`.
  """
  @spec list(map(), Wardrik.Scope.t(), kind(), String.t()) :: {:ok, [map()]} | {:error, Error.t()}
  def list(daemon, scope, kind, owner) do
    case @kinds[kind] do
      %{operation: operation} = settings ->
        listed = Map.get(settings, :listed, operation)

        with {:ok, %{^listed => items}} <-
               Wardrik.run(scope, operation <> ".list", %{"owner" => owner}),
             do: {:ok, Enum.map(items, &named/1)}

      %{store: store, kind: checked} ->
        with :ok <- Allowed.owned(daemon, scope, owner, {"#{checked}.read", checked}),
             do: {:ok, Enum.map(store.list(daemon, owner), &named/1)}
    end
  end

  @doc "Adds one of `kind` to the owner, or replaces the one with the same name."
  @spec add(map(), Wardrik.Scope.t(), kind(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  def add(daemon, scope, kind, owner, input) do
    case @kinds[kind] do
      %{operation: operation} ->
        with {:ok, added} <-
               Wardrik.run(scope, operation <> ".add", Map.put(input, "owner", owner)),
             do: {:ok, named(added)}

      %{store: store, kind: checked, input: schema} ->
        with {:ok, input} <- WardrikDaemon.HTTP.checked(schema, input),
             :ok <- Allowed.owned(daemon, scope, owner, {"#{checked}.add", checked}),
             {:ok, added} <- store.add(daemon, {owner, input}, scope.principal),
             do: {:ok, named(added)}
    end
  end

  @doc "Removes the owner's `name` of `kind`."
  @spec remove(map(), Wardrik.Scope.t(), kind(), String.t(), String.t()) ::
          :ok | {:error, Error.t()}
  def remove(daemon, scope, kind, owner, name) do
    case @kinds[kind] do
      %{operation: operation} ->
        input = %{"owner" => owner, "name" => name}
        with {:ok, _removed} <- Wardrik.run(scope, operation <> ".remove", input), do: :ok

      %{store: store, kind: checked} ->
        with :ok <- Allowed.owned(daemon, scope, owner, {"#{checked}.delete", checked}),
             {:ok, _removed} <- store.remove(daemon, {owner, name}, scope.principal),
             do: :ok
    end
  end

  # A notify target names its signing secret as %{"name" => name}.
  defp named(item) do
    Map.new(item, fn
      {"secret", %{"name" => name}} -> {"secret", name}
      pair -> pair
    end)
  end
end
