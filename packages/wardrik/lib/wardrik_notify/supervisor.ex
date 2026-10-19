defmodule WardrikNotify.Supervisor do
  @moduledoc """
  Runs `WardrikNotify`: the `DurableServer.Supervisor` its
  `WardrikNotify.Keeper` runs under, over the host's store, and the
  keeper, started here or found on another node of the cluster as it
  starts. `WardrikNotify.attach/2` makes it a child of the host, which
  `Wardrik` starts, handing it the host:

      {WardrikNotify.Supervisor,
       host: host,
       targets: [audit: {WardrikNotify.Webhook, url: "https://hooks.example.com/wardrik"}]}

  Options:

    * `:host` - the `Wardrik.Host` it was attached to: whose agents it
      tells of, and in whose store it keeps its place. Required.
    * `:targets` - each target by name, with the module that delivers to it
      and its options; see `WardrikNotify`. None by default.
    * `:req_options` - merged into every HTTP request a target makes, unless
      the target sets its own: the seam a test routes them through.
    * `:backoff` - how long it waits before trying a failed delivery again,
      in milliseconds, a second by default; see `WardrikNotify.Listener`.
    * `:name` - what the keeper's supervisor runs under,
      `WardrikNotify.Keepers` by default; the keeper keeps its place in the
      store under a prefix of that name.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    opts =
      Keyword.validate!(opts, [
        :host,
        name: WardrikNotify.Keepers,
        targets: [],
        req_options: [],
        backoff: 1_000
      ])

    name = Keyword.fetch!(opts, :name)
    store = opts |> Keyword.fetch!(:host) |> Wardrik.Host.store()

    children = [
      {DurableServer.Supervisor,
       [
         name: name,
         prefix: "notify/#{inspect(name)}/",
         backend: WardrikStore.durable_backend(store),
         init_info: Map.new(Keyword.take(opts, [:host, :targets, :req_options, :backoff]))
       ] ++ WardrikStore.durable_shutdown()},
      %{id: WardrikNotify.Keeper, start: {WardrikNotify.Keeper, :start, [name]}}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
