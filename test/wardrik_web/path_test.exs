defmodule WardrikWeb.PathTest do
  use ExUnit.Case, async: true

  test "paths encode each segment" do
    dashboard = %WardrikWeb.Dashboard{prefix: "/ops", resolver: {nil, nil}}

    assert WardrikWeb.path(dashboard, ["agents", "acme/triage"], %{"tab" => "runs", "x" => nil}) ==
             "/ops/agents/acme%2Ftriage?tab=runs"

    assert WardrikWeb.path(%{dashboard | prefix: "/"}, []) == "/"
  end
end
