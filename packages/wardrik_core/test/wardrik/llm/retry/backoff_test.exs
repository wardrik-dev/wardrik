defmodule Wardrik.LLM.Retry.BackoffTest do
  use ExUnit.Case, async: true

  alias ReqLLM.Error.API
  alias Wardrik.LLM.Attempt
  alias Wardrik.LLM.Config
  alias Wardrik.LLM.Request
  alias Wardrik.LLM.Retry
  alias Wardrik.LLM.Retry.Backoff

  defp failed(reason, times \\ 1) do
    Enum.reduce(1..times, Request.new(Config.new(), ReqLLM.Context.new()), fn _try, request ->
      Request.failed(request, %Attempt{model_spec: "test:m", reason: reason, answered?: false})
    end)
  end

  defp status(status, headers \\ []), do: API.Request.exception(status: status, headers: headers)

  test "waits a random while up to a second, then up to twice the last, at most max_wait" do
    backoff = %Backoff{attempts: 10, max_wait: 20_000}

    for tried <- 1..10, _draw <- 1..50 do
      assert {:again, wait, 10} = Retry.again(backoff, failed(:timeout, tried), [])
      assert wait in 0..min(20_000, 1_000 * 2 ** (tried - 1))
    end
  end

  test "draws the same waits from the same seed" do
    draw = fn ->
      :rand.seed(:exsss, {1, 2, 3})
      for tried <- 1..6, do: Retry.again(%Backoff{}, failed(:timeout, tried), [])
    end

    assert draw.() == draw.()
  end

  test "waits as long as Retry-After says, at most max_wait" do
    backoff = %Backoff{max_wait: 10_000}
    stream = fn error -> %API.Stream{reason: "Stream failed", cause: error} end

    assert {:again, 3_000, 6} =
             Retry.again(backoff, failed(stream.(status(429, [{"Retry-After", "3"}]))), [])

    assert {:again, 10_000, 6} =
             Retry.again(backoff, failed(status(503, [{"retry-after", "120"}])), [])
  end

  test "asks again after a 5xx, 408, 425, 429, a broken stream, or no status at all" do
    for reason <- [
          status(500),
          status(503),
          status(408),
          status(425),
          status(429),
          %API.Stream{reason: "Stream failed: {:error, {:case_clause, nil}}"},
          %API.Stream{reason: "Stream failed", cause: :timeout},
          %Mint.TransportError{reason: :closed},
          :timeout,
          :anything_else
        ] do
      assert {:again, _wait, 6} = Retry.again(%Backoff{}, failed(reason), []), inspect(reason)
    end
  end

  test "does what on_exhausted says at once for any other 4xx, wrapped or not" do
    for status <- [400, 401, 402, 403, 404, 422] do
      assert :ask = Retry.again(%Backoff{}, failed(status(status)), [])
      assert :fail = Retry.again(%Backoff{on_exhausted: :fail}, failed(status(status)), [])
    end

    wrapped = %API.Stream{reason: "Stream failed", cause: status(401)}
    assert :ask = Retry.again(%Backoff{}, failed(wrapped), [])
  end

  test "does what on_exhausted says once its tries are spent" do
    assert {:again, _wait, 2} = Retry.again(%Backoff{attempts: 2}, failed(:timeout, 2), [])
    assert :ask = Retry.again(%Backoff{attempts: 2}, failed(:timeout, 3), [])
    assert :fail = Retry.again(%Backoff{attempts: 0, on_exhausted: :fail}, failed(:timeout), [])
  end
end
