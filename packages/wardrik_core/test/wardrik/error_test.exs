defmodule Wardrik.ErrorTest do
  use ExUnit.Case, async: true

  alias Wardrik.Error

  test "says an agent is not found, and where a log's events were dropped" do
    assert %Error{type: :not_found, message: "No agent runs under acme/triage."} =
             Error.no_agent(Wardrik.AgentID.parse!("acme/triage"))

    assert %Error{type: :gap, details: %{"oldest" => 3}} = Error.gap(3)
  end
end
