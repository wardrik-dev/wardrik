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

# Budgets are kept by meters, and tool workers join a group, that core
# starts as a release does.
config :wardrik, :children, [WardrikPolicy.Supervisor]

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
