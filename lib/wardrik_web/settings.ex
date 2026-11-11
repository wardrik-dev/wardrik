defmodule WardrikWeb.Settings do
  @moduledoc """
  Gives a settings page its data: MCP servers, secrets, notify targets or OAuth apps.

  Your app keeps these settings. Wardrik reads them through your `Wardrik.Resolver`. Implement
  this behaviour to list, add and remove them from the dashboard, then turn the page on in the
  router:

      wardrik_dashboard "/wardrik",
        resolver: {MyAppWeb.WardrikResolver, []},
        settings: [servers: {MyApp.WardrikServers, []}]

  A page you don't turn on still shows in the navigation, with a note on how to turn it on.

  ## Example

      defmodule MyApp.WardrikServers do
        @behaviour WardrikWeb.Settings

        @impl true
        def owners(scope, _opts), do: MyApp.Teams.names_for(scope.principal.id)

        @impl true
        def list(_scope, owner, _opts),
          do: {:ok, Enum.map(MyApp.Servers.list(owner), &%{"name" => &1.name, "url" => &1.url})}

        @impl true
        def columns(_opts), do: [{"URL", "url"}]

        @impl true
        def schema(_opts) do
          %{
            "type" => "object",
            "required" => ["name", "url"],
            "properties" => %{
              "name" => %{"type" => "string"},
              "url" => %{"type" => "string", "format" => "uri"}
            }
          }
        end

        @impl true
        def add(_scope, owner, input, _opts), do: MyApp.Servers.add(owner, input)

        @impl true
        def remove(_scope, owner, name, _opts), do: MyApp.Servers.remove(owner, name)
      end

  ## Items

  `c:list/3` returns maps with string keys. The page reads these keys:

    * `"name"` - required. The page shows it first and removes items by it.
    * `"owner"` - the owner the item belongs to, when it isn't the chosen owner. The page shows
      it and doesn't offer to remove the item.
    * `"fixed"` - why the item can't be removed here, for example `"Set in config.yaml"`.

  `c:columns/1` names the other keys to show.

  ## Errors

  Return `{:error, %Wardrik.Error{}}` or `{:error, message}`. The page shows the message. Check
  that the person may act on the owner in each callback.
  """

  @typedoc "Your options, as given in the router."
  @type opts() :: term()

  @typedoc "An item, as a map with string keys. See the module docs."
  @type item() :: %{required(String.t()) => term()}

  @typedoc "An error the page shows."
  @type error() :: {:error, Wardrik.Error.t() | String.t()}

  @doc "Returns the owners the person can pick from. The page shows the first one first."
  @callback owners(Wardrik.Scope.t(), opts()) :: [String.t()]

  @doc "Returns the owner's items."
  @callback list(Wardrik.Scope.t(), owner :: String.t(), opts()) :: {:ok, [item()]} | error()

  @doc "Returns the columns to show after the name, as `{label, key}`."
  @callback columns(opts()) :: [{String.t(), String.t()}]

  @doc """
  Returns the JSON Schema of the form that adds an item. Fields marked `"writeOnly": true` are
  password fields.
  """
  @callback schema(opts()) :: map()

  @doc "Adds an item to the owner, or replaces the item with the same name."
  @callback add(Wardrik.Scope.t(), owner :: String.t(), input :: map(), opts()) ::
              {:ok, item()} | error()

  @doc "Removes the owner's item `name`."
  @callback remove(Wardrik.Scope.t(), owner :: String.t(), name :: String.t(), opts()) ::
              :ok | error()

  @doc """
  Returns the fields to show before "More settings". Defaults to the schema's required fields.
  """
  @callback common(opts()) :: [String.t()]

  @optional_callbacks common: 1
end
