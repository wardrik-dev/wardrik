defmodule Wardrik.LLM.Retry.BackoffTest do
  use ExUnit.Case, async: true

  alias Wardrik.LLM.Attempt
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Retry.Backoff

  defp failed(reasons, answered? \\ false) do
    Enum.reduce(reasons, Request.new(Config.new(), ReqLLM.Context.new()), fn reason, request ->
      Request.failed(request, %Attempt{model_spec: "test:m", reason: reason, answered?: answered?})
    end)
  end

  test "asks again after the wait for each try, while the failure is transient" do
    assert Backoff.again(failed([:timeout]), nil, [100, 200]) == {:again, 100}
    assert Backoff.again(failed([:timeout, :closed]), nil, [100, 200]) == {:again, 200}
  end

  test "asks again once the provider had begun to answer" do
    assert Backoff.again(failed([:closed], true), nil, [100]) == {:again, 100}
  end

  test "stops once its waits are spent, or for a failure that is not transient" do
    assert Backoff.again(failed([:timeout, :timeout, :timeout]), nil, [100, 200]) == :stop
    assert Backoff.again(failed([:timeout]), nil, []) == :stop
    assert Backoff.again(failed([{:policy_denied, "no"}]), nil, [100]) == :stop
  end
end
