defmodule WardrikACP do
  @options NimbleOptions.new!(
             name: [
               type: :atom,
               required: true,
               doc: "The name agents and functions use to find it."
             ],
             harnesses: [
               type: {:list, {:tuple, [{:or, [:atom, :string]}, :keyword_list]}},
               default: [],
               doc: "Coding agents, as a list of name and options. See `WardrikACP.Harness`."
             ],
             checkouts: [
               type: {:list, {:tuple, [{:or, [:atom, :string]}, :string]}},
               default: [],
               doc: "Git repositories coding agents work in, as a list of name and path."
             ],
             worktrees: [
               type: :string,
               required: true,
               doc: "The directory for worktrees, one per piece of work."
             ]
           )

  @moduledoc """
  Gives WardrikCore agents coding agents, such as Claude Code, as tools. Each one runs over the
  Agent Client Protocol (ACP).

      children = [
        {WardrikACP,
         name: MyApp.ACP,
         worktrees: "/var/lib/my_app/worktrees",
         checkouts: [billing: "/srv/billing"],
         harnesses: [claude: [command: "claude-agent-acp"]]}
      ]

      WardrikCore.start_agent(
        agent_id: "builder",
        model: "anthropic:claude-haiku-4-5",
        capabilities: [{WardrikACP, name: MyApp.ACP, harnesses: [:claude]}],
        middleware: [{WardrikPolicy.Middleware, WardrikPolicy.new!(ask: ["claude/execute"])}]
      )

    * The model sees a tool named `claude`. Its arguments are `task`, `checkout` and `work`.
    * Each `work` name has its own worktree, branch and session. Calling it again continues them.
    * Each permission request from the coding agent runs through the agent's middleware as a tool
      call named `claude__execute`, `claude__edit`, and so on, by ACP tool kind. Its arguments
      are the request's `rawInput`.
    * A request that parks parks the call. Answer it by the call's ID, as for any tool call.
    * The answer lists the branch, its commits, and the coding agent's last message.
    * Harness options are in `WardrikACP.Harness`.

  ## Telemetry

    * `[:wardrik_acp, :update]` for each session update. Metadata: `:agent_id`, `:span`,
      `:harness`, `:update` (the ACP `SessionUpdate` map).
  """
  @behaviour WardrikCore.Capability
  use Supervisor

  alias WardrikACP.Connection
  alias WardrikACP.Harness

  @doc """
  Starts `WardrikACP`. Coding agents start when a call first needs them.

  ## Options

  #{NimbleOptions.docs(@options)}
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @options)
    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl Supervisor
  def init(opts) do
    settings = %{
      acp: opts[:name],
      harnesses:
        Map.new(opts[:harnesses], fn {name, harness} ->
          {to_string(name), Harness.new!(name, harness)}
        end),
      checkouts:
        Map.new(opts[:checkouts], fn {name, path} -> {to_string(name), Path.expand(path)} end),
      worktrees: Path.expand(opts[:worktrees])
    }

    children = [
      {Registry,
       keys: :unique, name: Connection.registry(opts[:name]), meta: [settings: settings]},
      {DynamicSupervisor, name: Connection.supervisor(opts[:name])}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Returns a tool for each of the named coding agents.

  ## Options

    * `:name` - required. The `WardrikACP` name.
    * `:harnesses` - required. A coding agent's name or a list of them, as `:claude`.
    * `:checkouts` - the checkouts the tools may work in. All of them by default.
  """
  @impl WardrikCore.Capability
  def tools(_context, opts) do
    acp = Keyword.fetch!(opts, :name)
    {:ok, settings} = Registry.meta(Connection.registry(acp), :settings)

    checkouts =
      opts |> Keyword.get(:checkouts, Map.keys(settings.checkouts)) |> Enum.map(&to_string/1)

    opts
    |> Keyword.fetch!(:harnesses)
    |> List.wrap()
    |> Enum.map(
      &WardrikACP.Tool.new(settings, Map.fetch!(settings.harnesses, to_string(&1)), checkouts)
    )
  end
end
