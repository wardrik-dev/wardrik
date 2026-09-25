import Config

# Read when a release boots, so a build carries no keys and a key that is
# absent is a tool reporting it at call time rather than a node refusing to
# start.
if config_env() == :prod do
  config :tars, TarsBrave, api_key: System.get_env("BRAVE_API_KEY")

  config :req_llm, zai_api_key: System.get_env("ZAI_API_KEY")

  if key = System.get_env("TARS_VAULT_KEY") do
    config :tars, TarsVault, keys: [key]
  end
end

# A release is the daemon: it starts the budget meters, the tool workers'
# group and TarsDaemon beside core, and logs to
# TARS_STATE_DIR/log/tars.log, or to the terminal where TARS_LOG is "-".
if System.get_env("RELEASE_NAME") do
  config :tars, :cluster, [TarsDaemon.Cluster, TarsDaemon.Cluster.Quorum]
  config :tars, :children, [TarsPolicy.Supervisor, TarsHTTP.Workers, TarsDaemon]

  # config.yaml's cluster is read here, since what it describes starts before
  # TarsDaemon reads the rest of the file: the topologies that connect this
  # node to the others, and the size the store counts a quorum against. A file
  # that does not read is left for TarsDaemon to report.
  with {:ok, file} <- TarsDaemon.Config.file(TarsDaemon.Config.config_dir()),
       {:ok, settings} <- TarsDaemon.Config.read(file),
       {:ok, cluster} <- Keyword.fetch(settings, TarsDaemon.Cluster) do
    config :tars, TarsDaemon.Cluster, cluster

    if size = cluster[:size] do
      config :tars, Tars.Store, cluster_size: size
    end
  end

  state =
    System.get_env("TARS_STATE_DIR") ||
      Path.join(System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state"), "tars")

  case System.get_env("TARS_LOG") || Path.join([state, "log", "tars.log"]) do
    "-" ->
      :ok

    file ->
      config :logger, :default_handler,
        config: [file: String.to_charlist(file), max_no_bytes: 10_000_000, max_no_files: 5]

      config :logger, :default_formatter, colors: [enabled: false]
  end
end
