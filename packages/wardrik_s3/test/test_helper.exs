# The tests that reach real services, which dev/services.sh starts, are
# left out where nothing answers; see WardrikS3.Test.Services.
ExUnit.start(
  exclude: WardrikS3.Test.Services.start(),
  capture_log: true,
  assert_receive_timeout: 1_000
)
