import Config

config :logger, level: :warning

# The fleet writes to a real store, so the suite gets one of its own, unique
# per run so two suites can run side by side. test_helper.exs removes it.
config :wardrik, Wardrik.Store,
  adapter: Wardrik.Store.EKV,
  data_dir:
    Path.join([
      System.tmp_dir!(),
      "wardrik-test",
      "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    ])

config :wardrik, Wardrik.Fleet, org: "default"

# OAuth hosts resolve without DNS, and a device flow polls as often as the
# test's stub server asks.
config :wardrik_oauth, WardrikOAuth, resolver: WardrikOAuth.Case.Resolver, poll_floor: 0

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
