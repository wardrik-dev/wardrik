defmodule WardrikWeb.Connections do
  @moduledoc """
  Gives the Connections page its data: the signed-in person's accounts on other services.

  Agents call those services as the person who connected the account. Implement this behaviour
  to list, connect and disconnect accounts, then turn the page on in the router:

      wardrik_dashboard "/wardrik",
        resolver: {MyAppWeb.WardrikResolver, []},
        settings: [connections: {MyApp.WardrikConnections, []}]

  ## Connections

  `c:list/2` returns maps with string keys:

    * `"provider"` - required. The service's name.
    * `"connected"` - `true` once the account is connected.
    * `"signing_in"` - `true` while a sign-in is in progress.

  ## Signing in

  `c:connect/3` returns `{:ok, connecting}`, where `connecting` is a map with `"provider"` and
  either `"connected" => true` or an `"authorization"`:

    * `%{"url" => url}` - the page opens `url`. The service then shows a code, and the person
      enters it on the page. The page calls `c:pair/4` with the code.
    * `%{"url" => url, "code" => code}` - the person enters `code` at `url`. The page refreshes
      until the account is connected.
  """

  @typedoc "Your options, as given in the router."
  @type opts() :: term()

  @typedoc "An error the page shows."
  @type error() :: {:error, Wardrik.Error.t() | String.t()}

  @doc "Returns the person's connections, connected or not."
  @callback list(Wardrik.Scope.t(), opts()) :: {:ok, [map()]} | error()

  @doc "Starts connecting the person's account on `provider`."
  @callback connect(Wardrik.Scope.t(), provider :: String.t(), opts()) :: {:ok, map()} | error()

  @doc "Finishes connecting with the code the service showed."
  @callback pair(Wardrik.Scope.t(), provider :: String.t(), code :: String.t(), opts()) ::
              :ok | error()

  @doc "Disconnects the person's account on `provider`."
  @callback disconnect(Wardrik.Scope.t(), provider :: String.t(), opts()) :: :ok | error()
end
