defmodule WardrikResearchTest do
  use ExUnit.Case, async: true

  test "attaches deep research among the host's tools, as deep_research" do
    host = WardrikResearch.attach(Wardrik.Host.new())

    assert Wardrik.Host.tools(host) == %{"deep_research" => WardrikResearch.Deep}
    assert_raise ArgumentError, fn -> WardrikResearch.attach(Wardrik.Host.new(), angles: []) end
  end
end
