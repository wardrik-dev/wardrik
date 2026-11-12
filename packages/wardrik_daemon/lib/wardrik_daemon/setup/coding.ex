defmodule WardrikDaemon.Setup.Coding do
  @moduledoc """
  Offers Claude Code to agents as the `claude` harness, when `claude` or its ACP adapter,
  `claude-agent-acp`, is on `PATH`.

  Asks `coding.claude`. On yes, it adds `harnesses` to `config.yaml` and writes
  `policies/coding.yaml`, where every change asks a person and deletes are refused.

    * The harness runs the adapter with `PATH` as `wardrik init` found it, since a daemon under
      systemd starts with a shorter one, without Node.js.
    * Without the adapter, it shows the command that installs it. It never runs one.
    * Claude Code signs in with its own login. Without `~/.claude/.credentials.json`, an
      `ANTHROPIC_API_KEY` set here is passed to it.
    * A `config.yaml` with `harnesses` is left as it is.
  """

  @behaviour WardrikDaemon.Setup.Step

  alias WardrikDaemon.EnvFile
  alias WardrikDaemon.Setup.Machine
  alias WardrikDaemon.Setup.Question

  @adapter "claude-agent-acp"
  @install "npm install -g @agentclientprotocol/claude-agent-acp"
  @key "ANTHROPIC_API_KEY"

  @impl WardrikDaemon.Setup.Step
  def detect(%Machine{} = machine) do
    claude = Machine.executable(machine, "claude")
    adapter = Machine.executable(machine, @adapter)

    if (claude || adapter) && not Map.has_key?(Machine.config(machine), "harnesses") do
      %{
        adapter: adapter,
        path: Map.get(machine.env, "PATH", ""),
        key?: not signed_in?(machine) and keyed?(machine)
      }
    end
  end

  defp signed_in?(machine), do: File.exists?(Machine.home(machine, ".claude/.credentials.json"))

  defp keyed?(machine),
    do:
      Map.has_key?(machine.env, @key) or
        Map.has_key?(EnvFile.load(machine.dirs.env_file, %{}), @key)

  @impl WardrikDaemon.Setup.Step
  def questions(nil), do: []

  def questions(_found),
    do: [
      %Question{key: "coding.claude", label: "Found Claude Code. Let agents use it for coding?"}
    ]

  @impl WardrikDaemon.Setup.Step
  def plan(found, %{"coding.claude" => true}) do
    [
      {:section, "config.yaml", "harnesses", harnesses(found)},
      {:write, "policies/coding.yaml", policy()}
    ] ++ installed(found)
  end

  def plan(_found, _answers), do: []

  defp installed(%{adapter: nil}),
    do: [{:command, @install, "Claude Code works with Wardrik through its ACP adapter."}]

  defp installed(_found), do: []

  defp harnesses(found) do
    """
    # Coding agents, each a tool of the same name, as tools: [claude]. Each piece of work runs in a
    # worktree of a checkout, on a branch of its own. List the repositories under checkouts, as
    # checkouts: {app: ~/src/app}.
    harnesses:
      claude:
        command: #{found.adapter || @adapter}
        env:
          PATH: #{inspect(found.path)}#{key(found)}
        meta: {claudeCode: {options: {settingSources: []}}}
        options: {mode: default}
        context: [CLAUDE.md, AGENTS.md]
    """
  end

  defp key(%{key?: true}), do: "\n      #{@key}: ${#{@key}}"
  defp key(_found), do: ""

  defp policy do
    """
    # For workers that code: reading runs, each change asks a person, and deleting is refused.
    deny: [claude/delete]
    default: {read_only: allow, else: ask}
    """
  end
end
