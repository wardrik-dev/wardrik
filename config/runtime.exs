import Config

# Read when a release boots, so a build carries no keys and a key that is
# absent is a tool reporting it at call time rather than a node refusing to
# start.
if config_env() == :prod do
  config :wardrik, WardrikBrave, api_key: System.get_env("BRAVE_API_KEY")

  config :req_llm, zai_api_key: System.get_env("ZAI_API_KEY")

  if key = System.get_env("WARDRIK_VAULT_KEY") do
    config :wardrik, WardrikVault, keys: [key]
  end
end

# A release is the daemon: it starts the budget meters, the tool workers'
# group and WardrikDaemon beside core, and logs to
# WARDRIK_STATE_DIR/log/wardrik.log, or to the terminal where WARDRIK_LOG is "-".
if System.get_env("RELEASE_NAME") do
  config :wardrik, :cluster, [WardrikDaemon.Cluster, WardrikDaemon.Cluster.Quorum]
  config :wardrik, :children, [WardrikPolicy.Supervisor, WardrikHTTP.Workers, WardrikDaemon]

  # config.yaml's storage and cluster are read here, since what they describe
  # starts before WardrikDaemon reads the rest of the file: the store, the
  # topologies that connect this node to the others, and the size the store
  # counts a quorum against. A file that does not read is left for
  # WardrikDaemon to report.
  with {:ok, file} <- WardrikDaemon.Config.file(WardrikDaemon.Config.config_dir()),
       {:ok, settings} <- WardrikDaemon.Config.read(file) do
    config :wardrik, WardrikDaemon.Config.boot(settings)
  end

  state =
    System.get_env("WARDRIK_STATE_DIR") ||
      Path.join(System.get_env("XDG_STATE_HOME") || Path.expand("~/.local/state"), "wardrik")

  case System.get_env("WARDRIK_LOG") || Path.join([state, "log", "wardrik.log"]) do
    "-" ->
      :ok

    file ->
      config :logger, :default_handler,
        config: [file: String.to_charlist(file), max_no_bytes: 10_000_000, max_no_files: 5]

      config :logger, :default_formatter, colors: [enabled: false]
  end
end
