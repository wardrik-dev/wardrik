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
               type:
                 {:list, {:tuple, [{:or, [:atom, :string]}, {:or, [:string, :keyword_list]}]}},
               default: [],
               doc:
                 "Git repositories coding agents work in, as a list of name and path or options. See `WardrikACP.Checkout`."
             ],
             sweep: [
               type: {:or, [:pos_integer, {:in, [:infinity]}]},
               default: :timer.hours(24),
               doc:
                 "Milliseconds between sweeps, or `:infinity`. The first runs at start. See `sweep/1`."
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
        middleware: [{Wardrik.Policy.Middleware, Wardrik.Policy.new!(ask: ["claude/execute"])}]
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

    * `[:wardrik_acp, :sweep]` after each sweep. Measurements: `:removed`. Metadata: `:acp`,
      `:removed` (the paths).

    * `[:wardrik_acp, :update]` for each session update. Metadata: `:agent_id`, `:span`,
      `:harness`, `:update` (the ACP `SessionUpdate` map).
  """
  @behaviour WardrikCore.Capability
  use Supervisor

  alias WardrikACP.Checkout
  alias WardrikACP.Connection
  alias WardrikACP.Harness
  alias WardrikACP.Sweep

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
        Map.new(opts[:checkouts], fn {name, checkout} ->
          {to_string(name), Checkout.new!(name, checkout)}
        end),
      worktrees: Path.expand(opts[:worktrees]),
      sweep: opts[:sweep]
    }

    children = [
      {Registry,
       keys: :unique, name: Connection.registry(opts[:name]), meta: [settings: settings]},
      {DynamicSupervisor, name: Connection.supervisor(opts[:name])}
    ]

    children = if settings.sweep == :infinity, do: children, else: children ++ [{Sweep, settings}]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Removes each worktree whose work is in its checkout's `base`, with its branch. Returns the paths
  removed.

      WardrikACP.sweep(MyApp.ACP)
      #=> ["/var/lib/my_app/worktrees/claude/billing/builder/_/fix-login"]

    * Work is in the base when merging the branch would change nothing: merged, squashed or
      cherry-picked.
    * A worktree stays while a call uses its coding agent, while a request waits, and while it
      has changes or untracked files. An idle coding agent is stopped first.
    * With `fetch: true`, the checkout runs `git fetch` first.
  """
  @spec sweep(atom()) :: [Path.t()]
  def sweep(acp) do
    {:ok, settings} = Registry.meta(Connection.registry(acp), :settings)
    Sweep.run(settings)
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
