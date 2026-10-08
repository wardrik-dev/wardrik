defmodule WardrikOAuth.Config do
  @moduledoc """
  The settings `WardrikOAuth` runs with: the options `WardrikOAuth.Supervisor`
  was started with, which it keeps in `:persistent_term` under
  `{WardrikOAuth, :settings}` as it starts.

      {WardrikOAuth.Supervisor,
       client: [name: "Wardrik", document_url: "https://wardrik.dev/oauth/client"],
       providers: [github: [resource: "https://api.githubcopilot.com/mcp/"]],
       redirect: [port: 4599, open: true],
       req_options: []}

  | Key | What it is |
  | --- | --- |
  | `:client` | the identity this deployment presents, see `WardrikOAuth.Client` |
  | `:providers` | what a user can authorize, see `WardrikOAuth.Provider` |
  | `:redirect` | where a code comes back to: `:uri`, `:port`, `:open`, `:opener` |
  | `:req_options` | merged into every request |
  | `:resolver` | the module whose `resolve/1` answers a host's addresses, `WardrikOAuth.Egress` by default |
  | `:poll_floor` | the fewest milliseconds between two polls of a device flow, 5 seconds by default |

  Where the supervisor was never started, every setting is its default, and
  no provider is configured.
  """

  @key {WardrikOAuth, :settings}
  @defaults [
    client: [],
    providers: [],
    redirect: [],
    req_options: [],
    resolver: WardrikOAuth.Egress,
    poll_floor: :timer.seconds(5)
  ]

  @doc "The keys `put/1` takes."
  @spec keys() :: [atom()]
  def keys, do: Keyword.keys(@defaults)

  @doc "Keeps `settings` in place of any kept before, each one left out at its default."
  @spec put(keyword()) :: :ok
  def put(settings), do: :persistent_term.put(@key, Keyword.validate!(settings, @defaults))

  @doc "Every setting, as last kept."
  @spec settings() :: keyword()
  def settings, do: :persistent_term.get(@key, @defaults)

  @spec client() :: keyword()
  def client, do: Keyword.fetch!(settings(), :client)

  @spec providers() :: keyword()
  def providers, do: Keyword.fetch!(settings(), :providers)

  @spec redirect() :: keyword()
  def redirect, do: Keyword.fetch!(settings(), :redirect)

  @spec req_options() :: keyword()
  def req_options, do: Keyword.fetch!(settings(), :req_options)

  @doc "The module whose `resolve/1` answers a host's addresses; see `WardrikOAuth.Egress`."
  @spec resolver() :: module()
  def resolver, do: Keyword.fetch!(settings(), :resolver)

  @doc "The fewest milliseconds between two polls of a device flow, whatever the server asks."
  @spec poll_floor() :: non_neg_integer()
  def poll_floor, do: Keyword.fetch!(settings(), :poll_floor)

  @doc "Whether any provider is configured."
  @spec configured?() :: boolean()
  def configured?, do: providers() != []
end
