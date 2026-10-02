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

config :wardrik, WardrikBrave,
  api_key: "test-brave-api-key",
  base_url: "https://brave.test",
  req_options: [plug: {Req.Test, WardrikBrave.Stub}, retry: false]

config :req_llm,
  load_dotenv: false,
  zai_api_key: "test-zai-api-key",
  receive_timeout: 1_000
