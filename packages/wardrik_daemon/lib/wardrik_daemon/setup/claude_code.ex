defmodule WardrikDaemon.Setup.ClaudeCode do
  @moduledoc """
  Offers Claude Code to agents as the `claude` harness, when `claude` or its ACP adapter,
  `claude-agent-acp`, is on `PATH` and `config.yaml` has no `claude` harness.

  Asks `coding.claude`. See `WardrikDaemon.Setup.Harness` for what a yes writes.

    * The harness runs the adapter with `PATH` as `wardrik init` found it, since a daemon under
      systemd starts with a shorter one, without Node.js.
    * Without the adapter, it shows the command that installs it. It never runs one.
    * Claude Code signs in with its own login. Without `~/.claude/.credentials.json`, an
      `ANTHROPIC_API_KEY` set here is passed to it.
  """

  @behaviour WardrikDaemon.Setup.Step

  alias WardrikDaemon.EnvFile
  alias WardrikDaemon.Setup.Harness
  alias WardrikDaemon.Setup.Machine
  alias WardrikDaemon.Setup.Question

  @adapter "claude-agent-acp"
  @key "ANTHROPIC_API_KEY"

  @impl WardrikDaemon.Setup.Step
  def detect(%Machine{} = machine) do
    adapter = Machine.executable(machine, @adapter)
    found? = adapter || Machine.executable(machine, "claude")

    if found? && Harness.missing?(machine, "claude") do
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
    Harness.added("claude", """
    command: #{found.adapter || @adapter}
    env:
      PATH: #{inspect(found.path)}#{key(found)}
    meta: {claudeCode: {options: {settingSources: []}}}
    options: {mode: default}
    context: [CLAUDE.md, AGENTS.md]
    """) ++ installed(found)
  end

  def plan(_found, _answers), do: []

  defp key(%{key?: true}), do: "\n  #{@key}: ${#{@key}}"
  defp key(_found), do: ""

  defp installed(%{adapter: nil}),
    do: [
      {:command, "npm install -g @agentclientprotocol/claude-agent-acp",
       "Claude Code works with Wardrik through its ACP adapter."}
    ]

  defp installed(_found), do: []
end
