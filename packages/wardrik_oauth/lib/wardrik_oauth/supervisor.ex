defmodule WardrikOAuth.Supervisor do
  @moduledoc """
  What `WardrikOAuth` needs running: the flows under way, each a process
  registered across the cluster (see `WardrikOAuth.Pending`), and the tasks
  that open a browser. Each flow carries its own `WardrikOAuth`.

      children = [WardrikOAuth.Supervisor]

  `WardrikOAuth.attach/2` makes it a child of the host, which `Wardrik`
  starts with `:host`, the one option it takes. The pages a browser comes
  back to are the host's to serve; see `WardrikOAuth.Callback`.
  """

  use Supervisor

  alias WardrikOAuth.Pending

  @doc "Starts the flows' registry and supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Keyword.validate!(opts, [:host])
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl Supervisor
  def init([]) do
    children = Pending.children() ++ [{Task.Supervisor, name: WardrikOAuth.Tasks}]

    # A flow runs only while the registry it is found in does.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end
