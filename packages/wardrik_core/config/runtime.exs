# Evaluated at runtime in every environment (including releases), after
# the compiled config. Read secrets and environment-dependent values here.
import Config

if config_env() != :test do
  for {env_var, key} <- [
        {"ANTHROPIC_API_KEY", :anthropic_api_key},
        {"OPENAI_API_KEY", :openai_api_key}
      ],
      value = System.get_env(env_var) do
    config :req_llm, [{key, value}]
  end
end
