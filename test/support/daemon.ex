defmodule WardrikDaemon.Test do
  @moduledoc "Writes a daemon's files under a test's own directory, and starts it there."

  import ExUnit.Assertions, only: [assert_receive: 2]
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  @model "anthropic:claude-haiku-4-5"

  def model, do: @model

  def dirs(context) do
    root = Path.join(System.tmp_dir!(), "wardrik_daemon #{System.unique_integer([:positive])}")
    File.rm_rf!(root)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(root) end)

    env = %{
      "HOME" => root,
      "WARDRIK_CONFIG_DIR" => Path.join(root, "config"),
      "WARDRIK_DATA_HOME" => Path.join(root, "data"),
      "WARDRIK_STATE_DIR" => Path.join(root, "state")
    }

    Map.merge(context, %{root: root, env: env})
  end

  def write(%{env: env}, name, text) do
    path = Path.join(env["WARDRIK_CONFIG_DIR"], name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, text)
    path
  end

  def free_port do
    {:ok, socket} = :gen_tcp.listen(0, [])
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  @doc "Starts the Postgres store the suite shares, where `DATABASE_URL` is set."
  def start_store do
    with url when is_binary(url) <- System.get_env("DATABASE_URL") do
      children = [{WardrikStore, WardrikStore.Ecto.new(url: url)}]
      {:ok, _supervisor} = Supervisor.start_link(children, strategy: :one_for_one)
    end
  end

  defp store(context) do
    if System.get_env("DATABASE_URL"),
      do:
        WardrikStore.scope(
          WardrikStore.Ecto.new(repo: WardrikStore.Ecto.Repo),
          "t#{System.unique_integer([:positive])}"
        ),
      else: WardrikStore.ETS.new(name: :"store #{context.test}")
  end

  @doc "Makes the agent `name` for `owner`, as the daemon's route does, and returns its ID."
  def agent(context, owner, name, definition \\ [model: @model]) do
    {:ok, record} =
      WardrikDaemon.AgentRecords.create(context.daemon_store, owner: owner, name: name)

    {:ok, _agent} = Wardrik.Agent.define(context.admin, record.id, definition)
    record.id
  end

  @doc """
  Returns the ID of a record for `label`, as `"payments/@ana/notes"`: owned by `payments/@ana`,
  and named after the whole label, so labels never share a name. Makes it the first time.
  """
  def recorded(context, label) do
    {owner, _name} = label |> String.split("/") |> Enum.split(-1)
    owner = Enum.join(owner, "/")
    name = label |> String.replace("@", "") |> String.replace("/", "-")
    org = WardrikDaemon.Owners.org(owner)

    case WardrikDaemon.AgentRecords.named(context.daemon_store, org, name) do
      {:ok, record} ->
        record.id

      :error ->
        {:ok, record} =
          WardrikDaemon.AgentRecords.create(context.daemon_store, owner: owner, name: name)

        record.id
    end
  end

  @doc "Returns the ID of the agent called `name` in `org`."
  def id(context, org, name) do
    {:ok, record} = WardrikDaemon.AgentRecords.named(context.daemon_store, org, name)
    record.id
  end

  def start_daemon(context) do
    name = :"wardrik #{context.test}"
    store = store(context)
    ref = :telemetry_test.attach_event_handlers(self(), [[:wardrik_daemon, :started]])

    {_pid, log} =
      ExUnit.CaptureLog.with_log(fn ->
        pid =
          start_supervised!(
            {WardrikDaemon.Server,
             env: context.env,
             name: name,
             store: store,
             capabilities:
               [echo: WardrikDaemon.Test.Tools] ++
                 WardrikDaemon.Capabilities.all(name, WardrikStore.scope(store, "wardrik_daemon"))}
          )

        assert_receive({[:wardrik_daemon, :started], ^ref, _measurements, _meta}, 5_000)
        pid
      end)

    admin = WardrikDaemon.Agents.scope(wardrik: name)

    Map.merge(context, %{
      wardrik: name,
      admin: admin,
      daemon_store: WardrikStore.scope(store, "wardrik_daemon"),
      log: log
    })
  end
end

defmodule WardrikDaemon.Test.Tools do
  @moduledoc "A capability with one tool, `echo`."
  @behaviour WardrikCore.Capability

  @impl WardrikCore.Capability
  def tools(_context, _opts) do
    [
      WardrikCore.Tool.new!(
        name: "echo",
        description: "Echoes text",
        schema: [text: [type: :string]],
        run: fn args, _context -> {:ok, Map.get(args, :text, "")} end
      )
    ]
  end
end
