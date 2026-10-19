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

  # Declares `orgs` beside the deployment's own, as config.yaml's orgs does.
  def declare(orgs) do
    own = Keyword.get(sections(), WardrikDaemon, [])
    put_section(WardrikDaemon, Keyword.put(own, :orgs, [Config.org(config()) | orgs]))
  end

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
    agents = Agents.of(host())

    %{
      agents
      | config: config,
        context: WardrikDaemon.AgentFile.context(config)
    }
  end

  # The test's directory, for its config, without starting anything.
  def use_dir(dir) do
    Process.put(@agents, dir)
    :ok
  end

  # Reads the files of `dir`, as the test's own, as the daemon does as it
  # starts.
  def start_agents(dir) do
    Process.put(@agents, dir)
    _reloaded = reload(agents(dir))
    agents(dir)
  end

  # Reads every definition again, the files of the test's directory among
  # them, as wardrik reload does.
  def reload(agents \\ agents()),
    do: Wardrik.Definitions.reload(Agents.definitions(agents), host: host())

  # The definitions of the directory start_agents/1 read, under the sections
  # the test has put so far.
  def agents, do: agents(Process.get(@agents) || System.tmp_dir!())

  # Keeps `fields` as the definition of `id`, as `source` wrote them, read
  # under the test's agents: the spec it writes.
  def define(id, fields, source) do
    definitions = Agents.definitions(agents())
    context = Agents.context(agents())

    with {:ok, definition} <-
           Wardrik.Definition.read(fields, id: id, source: source, context: context),
         :ok <- Wardrik.Definitions.put(definitions, definition),
         do: Wardrik.Definitions.spec(definitions, id, host: host())
  end

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
      Agents.of(host())
      | config: config,
        context: WardrikDaemon.AgentFile.context(config)
    }
  end

  defp with_sections(config, test) do
    %{config | sections: Config.merge(config().sections, dictionary(test)[@sections] || [])}
  end

  defp dictionary(test), do: Process.info(test, :dictionary) |> elem(1) |> Map.new()

  # The suite's host, with the test's definitions, and tokens issued from them.
  def host(%Agents{config: config} = agents) do
    store = Wardrik.Test.store()

    oauth = WardrikOAuth.new(Config.oauth_settings(config))

    settings = Keyword.take(Config.section(config, WardrikVault), [:keys, :shared])
    vault = WardrikVault.new([store: store, grants: oauth] ++ settings)

    %{
      host()
      | definitions: Agents.definitions(agents),
        credentials: vault,
        connections: %WardrikOAuth.Connections{oauth: oauth, vault: vault},
        triggers: %WardrikTrigger.Deliveries{
          secrets: &WardrikDaemon.Secrets.for_agent(vault, &1, &2)
        },
        issuer: %WardrikDaemon.Issuer{agents: agents}
    }
  end
end
