defmodule WardrikOAuth.Supervisor do
  @moduledoc """
  What `WardrikOAuth` needs running: the flows under way, each a process
  registered across the cluster (see `WardrikOAuth.Pending`), the tasks that
  open a browser, and the loopback the browser comes back to.

      children = [
        {WardrikOAuth.Supervisor,
         client: [name: "Wardrik", client_uri: "https://wardrik.dev"],
         providers: [github: [resource: "https://api.githubcopilot.com/mcp/"]]}
      ]

  `:client`, `:providers`, `:redirect`, `:req_options`, `:resolver` and
  `:poll_floor` are the settings every flow reads, as `WardrikOAuth.Config`
  describes them; it keeps them as it starts. A deployment serving its own
  redirect URI starts it with `loopback: false` and calls
  `WardrikOAuth.finish/2` from its own controller.
  """

  use Supervisor

  alias WardrikOAuth.Loopback
  alias WardrikOAuth.Pending

  @doc "Keeps the settings, and starts the flows' registry and supervisor, and the loopback listener unless told not to."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    :ok = WardrikOAuth.Config.put(Keyword.take(opts, WardrikOAuth.Config.keys()))

    children =
      Pending.children() ++ [{Task.Supervisor, name: WardrikOAuth.Tasks}] ++ loopback(opts)

    # A flow runs only while the registry it is found in does.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp loopback(opts) do
    if Keyword.get(opts, :loopback, true), do: [{Loopback, opts}], else: []
  end
end
