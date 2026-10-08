Mimic.copy(Ecto.Adapters.SQL)

# The tests that reach real services, which dev/services.sh starts, are
# left out where nothing answers; see WardrikEcto.Test.Services.
ExUnit.start(
  exclude: WardrikEcto.Test.Services.start(),
  capture_log: true,
  assert_receive_timeout: 1_000
)
