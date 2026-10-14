defmodule WardrikDaemon.Test.Host do
  @moduledoc false
  # The host the suite's fleet was started with, which test_helper.exs built
  # as a daemon builds one and holds where a command run over rpc finds it,
  # and what a test builds from it: a config with a directory of its own and
  # the sections it puts, and the daemon's definitions under that config,
  # sharing the suite's table, so the fleet's agents find what they read.

  alias WardrikDaemon.Agents
  alias WardrikDaemon.Config

  @sections {__MODULE__, :sections}
  @agents {__MODULE__, :agents}
  @nodes {__MODULE__, :nodes}

  # As test_helper.exs built them, past any stub of held/0.
  def host, do: elem(suite(), 0)

  def config, do: elem(suite(), 1)

  defp suite, do: Application.fetch_env!(:wardrik_daemon, __MODULE__)

  # What config.yaml would say of `module`, for the config this test builds.
  def put_section(module, opts) do
    Process.put(@sections, Keyword.put(sections(), module, opts))
    :ok
  end

  def sections, do: Process.get(@sections, [])

  def config(dir) do
    base = config()

    %{
      base
      | config_dir: dir,
        data_dir: dir,
        state_dir: dir,
        sections: Config.merge(base.sections, sections())
    }
  end

  def agents(dir) do
    config = config(dir)

    %{
      Wardrik.Host.definitions(host())
      | config: config,
        context: WardrikDaemon.AgentFile.context(config),
        nodes: Process.get(@nodes, &Node.list/0)
    }
  end

  # The other nodes whose inventories the test's definitions count.
  def put_nodes(nodes) do
    Process.put(@nodes, nodes)
    :ok
  end

  # The test's directory, for its config, without starting anything.
  def use_dir(dir) do
    Process.put(@agents, dir)
    :ok
  end

  # Starts the daemon's definitions reading `dir`, as the test's own.
  def start_agents(dir) do
    Process.put(@agents, dir)
    ExUnit.Callbacks.start_supervised!({Agents, agents: agents(dir)})
    agents(dir)
  end

  # The definitions of the directory start_agents/1 read, under the sections
  # the test has put so far.
  def agents, do: agents(Process.get(@agents) || System.tmp_dir!())

  # A command run over rpc finds the test's host and config where the
  # daemon's tree holds them: those of the directory start_agents/1 read, as
  # the test asks.
  def held do
    test = self()
    Mimic.stub(WardrikDaemon.Host, :get, fn -> host(agents_of(test)) end)
    Mimic.stub(WardrikDaemon.Host, :config, fn -> config(dir_of(test)) |> with_sections(test) end)
    Mimic.stub(WardrikDaemon.Host, :agents, fn -> agents_of(test) end)

    Mimic.stub(WardrikDaemon.Boot, :cluster, fn ->
      Keyword.get(dictionary(test)[@sections] || [], WardrikDaemon.Cluster, [])
    end)

    :ok
  end

  defp dir_of(test), do: dictionary(test)[@agents] || System.tmp_dir!()

  defp agents_of(test) do
    config = config(dir_of(test)) |> with_sections(test)

    %{
      Wardrik.Host.definitions(host())
      | config: config,
        context: WardrikDaemon.AgentFile.context(config),
        nodes: dictionary(test)[@nodes] || (&Node.list/0)
    }
  end

  defp with_sections(config, test) do
    %{config | sections: Config.merge(config().sections, dictionary(test)[@sections] || [])}
  end

  defp dictionary(test), do: Process.info(test, :dictionary) |> elem(1) |> Map.new()

  # The suite's host, with the test's definitions, and grants read from them.
  def host(%Agents{config: config} = agents) do
    store = Wardrik.Test.store()

    oauth =
      WardrikOAuth.new(
        Keyword.take(Config.section(config, WardrikOAuth), [:client, :providers, :redirect])
      )

    settings = Keyword.take(Config.section(config, WardrikVault), [:keys, :environment])
    vault = WardrikVault.new([store: store, grants: oauth] ++ settings)

    %{
      host()
      | definitions: agents,
        credentials: vault,
        connections: %WardrikOAuth.Connections{oauth: oauth, vault: vault},
        triggers: %WardrikTrigger.Deliveries{
          secrets: &WardrikDaemon.Secrets.for_agent(vault, &1, &2)
        },
        grants: %WardrikDaemon.Grants{store: store, agents: agents}
    }
  end
end
