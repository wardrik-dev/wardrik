defmodule WardrikOAuth.SupervisorTest do
  use WardrikOAuth.Test.Case, async: false

  test "keeps the settings it starts with, each one left out at its default" do
    providers = [github: [resource: resource()]]
    start_supervised!({WardrikOAuth.Supervisor, loopback: false, providers: providers})

    assert WardrikOAuth.Config.providers() == providers
    assert WardrikOAuth.Config.configured?()
    assert WardrikOAuth.Config.resolver() == WardrikOAuth.Egress
    assert WardrikOAuth.Config.poll_floor() == :timer.seconds(5)
  end

  test "refuses a setting it does not have" do
    assert_raise ArgumentError, fn -> WardrikOAuth.Config.put(provider: []) end
  end
end
