defmodule WardrikDaemon.HarnessesTest do
  use ExUnit.Case, async: true

  alias WardrikDaemon.AgentRecords
  alias WardrikDaemon.Config

  setup context do
    store = Wardrik.Store.ETS.new(name: :"store #{context.test}")
    start_supervised!({Wardrik.Store, store})
    store = Wardrik.Store.scope(store, "wardrik_daemon", format: Wardrik.Store.Format.Term)
    wardrik = Module.concat(__MODULE__, "W#{System.unique_integer([:positive])}")
    dir = Path.join(System.tmp_dir!(), "harnesses_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    config = %Config{
      org: "platform",
      orgs: %{"payments" => %{entry() | harnesses: ["claude"]}},
      harnesses: [{"claude", [command: "claude-agent-acp"]}, {"codex", [command: "codex-acp"]}],
      checkouts: [{"core", [path: dir]}]
    }

    start_supervised!(
      {WardrikACP,
       name: WardrikDaemon.Harnesses.acp(wardrik),
       worktrees: Path.join(dir, "worktrees"),
       checkouts: config.checkouts,
       harnesses: config.harnesses}
    )

    %{store: store, wardrik: wardrik, config: config}
  end

  test "names a tool after each harness, for the orgs that use it", context do
    capabilities =
      WardrikDaemon.Harnesses.capabilities(context.wardrik, context.store, context.config)

    assert ["claude", "codex"] = Enum.map(capabilities, &elem(&1, 0))

    offered = fn owner ->
      {:ok, record} =
        AgentRecords.create(context.store, owner: owner, name: "builder", source: :api)

      agent = WardrikCore.Context.new(agent_id: record.id)

      for {_name, {module, opts}} <- capabilities,
          tool <- module.tools(agent, opts),
          do: tool.name
    end

    assert offered.("payments") == ["claude"]
    assert offered.("platform") == ["codex"]
    assert offered.("growth") == []
  end

  defp entry, do: %{mcp: [], harnesses: [], rest: [], channels: [], notify: [], policy: nil}
end
