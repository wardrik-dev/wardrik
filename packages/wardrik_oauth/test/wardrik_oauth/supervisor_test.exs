defmodule WardrikOAuth.SupervisorTest do
  use WardrikOAuth.Test.Case, async: false

  test "starts the flows' registry and the tasks that open a browser" do
    start_supervised!(WardrikOAuth.Supervisor)

    assert Process.whereis(WardrikOAuth.Tasks)
  end

  test "each setting left out is at its default, and one it does not have is refused" do
    oauth = WardrikOAuth.new(providers: [github: [resource: resource()]])

    assert WardrikOAuth.configured?(oauth)
    refute WardrikOAuth.configured?(WardrikOAuth.new())
    assert oauth.resolve == (&WardrikOAuth.Egress.resolve/1)
    assert oauth.poll_floor == :timer.seconds(5)
    assert_raise ArgumentError, fn -> WardrikOAuth.new(provider: []) end
  end
end
