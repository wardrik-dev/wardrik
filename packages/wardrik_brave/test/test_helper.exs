:ok = DurableServer.Supervisor.wait_until_ready(Wardrik.Fleet, timeout: 10_000)

ExUnit.start(capture_log: true, assert_receive_timeout: 1_000)
