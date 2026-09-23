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
