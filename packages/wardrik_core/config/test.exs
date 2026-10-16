import Config

config :logger, level: :warning

# The fleet writes to a real store, so the suite gets one of its own, unique
# per run so two suites can run side by side. test_helper.exs removes it.
config :wardrik_core, Wardrik.Test,
  store: [
    adapter: WardrikStore.EKV,
    data_dir:
      Path.join([
        System.tmp_dir!(),
        "wardrik-test",
        "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}"
      ])
  ],
  # Every agent the suite starts asks these for the definition it runs on.
  host: [definitions: {Wardrik.Test.Definitions, []}]

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
