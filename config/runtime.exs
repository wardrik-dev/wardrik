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

# A release is the daemon: it starts TarsDaemon beside core and logs to
# TARS_STATE_DIR/log/tars.log, or to the terminal where TARS_LOG is "-".
if System.get_env("RELEASE_NAME") do
  config :tars, :children, [TarsDaemon]

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
