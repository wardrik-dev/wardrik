defmodule WardrikCore.RetryTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Retry

  defp waits(retries, reason) do
    test = self()

    {:spent, _answer, _tries} =
      Retry.run(retries, fn -> {:error, reason} end,
        transient: fn {:error, reason} -> reason end,
        announce: &send(test, {:waited, &1.wait_ms})
      )

    for _attempt <- 1..Retry.attempts(retries) do
      assert_receive {:waited, wait}
      wait
    end
  end

  test "waits as long as a provider's Retry-After says, from either header shape" do
    limited = %ReqLLM.Error.API.Request{status: 429, headers: [{"retry-after", "0"}]}
    assert waits([attempts: 2, max_wait: 50], limited) == [0, 0]

    req = %ReqLLM.Error.API.Request{status: 429, headers: %{"retry-after" => ["0"]}}
    assert waits([attempts: 1, max_wait: 50], req) == [0]
  end

  test "never waits past max_wait, even when Retry-After asks for longer" do
    limited = %ReqLLM.Error.API.Request{status: 429, headers: [{"retry-after", "30"}]}
    assert waits([attempts: 2, max_wait: 20], limited) == [20, 20]
  end

  test "backs off on its own when Retry-After is missing or a date" do
    dated = %ReqLLM.Error.API.Request{
      status: 503,
      headers: [{"retry-after", "Wed, 21 Oct 2026 07:28:00 GMT"}]
    }

    for reason <- [dated, %ReqLLM.Error.API.Request{status: 503, headers: []}, :timeout] do
      assert [wait] = waits([attempts: 1, max_wait: 20], reason)
      assert wait in 1..20
    end
  end
end
