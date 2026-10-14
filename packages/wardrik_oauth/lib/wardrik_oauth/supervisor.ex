defmodule WardrikOAuth.Supervisor do
  @moduledoc """
  What `WardrikOAuth` needs running: the flows under way, each a process
  registered across the cluster (see `WardrikOAuth.Pending`), the tasks that
  open a browser, and the callback the browser comes back to (see
  `WardrikOAuth.Callback`).

      oauth = WardrikOAuth.new(providers: [github: [resource: "https://api.githubcopilot.com/mcp/"]])
      children = [{WardrikOAuth.Supervisor, oauth: oauth}]

  `:oauth` is the `WardrikOAuth` the callback answers under; each flow
  carries its own. A deployment serving its own redirect URI starts it with
  `callback: false` and calls `WardrikOAuth.finish/3` from its own
  controller.
  """

  use Supervisor

  alias WardrikOAuth.Callback
  alias WardrikOAuth.Pending

  @doc "Starts the flows' registry and supervisor, and the callback listener unless told not to."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    children =
      Pending.children() ++ [{Task.Supervisor, name: WardrikOAuth.Tasks}] ++ loopback(opts)

    # A flow runs only while the registry it is found in does.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp loopback(opts) do
    if Keyword.get(opts, :callback, true), do: [{Callback, opts}], else: []
  end
end
