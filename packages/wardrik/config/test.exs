import Config

config :logger, level: :warning

# The fleet writes to a real store, so the suite gets one of its own, unique
# per run so two suites can run side by side. test_helper.exs removes it.
config :wardrik, WardrikStore,
  adapter: WardrikStore.EKV,
  data_dir:
    Path.join([
      System.tmp_dir!(),
      "wardrik-test",
      "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
    ])

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000

# Every agent the suite starts asks these for the definition it runs on.
config :wardrik, Wardrik.Host, definitions: Wardrik.Test.Definitions
