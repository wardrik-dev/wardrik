defmodule Wardrik.FailureTest do
  use ExUnit.Case, async: true

  alias Wardrik.Failure

  describe "classify/1" do
    test "reads a dropped or refused connection as worth retrying" do
      for reason <- [:timeout, :closed, :econnrefused, :nxdomain, :pool_timeout] do
        assert Failure.classify(reason) == :transient
      end
    end

    test "reads a limit doing its job as a ceiling" do
      for reason <- [:interrupted, :deadline_exceeded, :max_iterations, :denied] do
        assert Failure.classify(reason) == :ceiling
      end
    end

    test "reads a policy refusal as a ceiling whatever it carries" do
      assert Failure.classify({:policy_denied, "not this quarter"}) == :ceiling
    end

    test "classifies a tagged reason by its tag" do
      assert Failure.classify({:timeout, 5_000}) == :transient
      assert Failure.classify({:deadline_exceeded, 0}) == :ceiling
    end

    test "treats anything it does not recognise as a bug rather than a blip" do
      assert Failure.classify(:something_new) == :bug
      assert Failure.classify("a sentence") == :bug
      assert Failure.classify(%{unexpected: true}) == :bug
    end

    test "reads a retryable HTTP status off an exception" do
      assert Failure.classify(%RuntimeError{message: "x"}) == :bug
      assert Failure.classify(%{__exception__: true, status: 429}) == :transient
      assert Failure.classify(%{__exception__: true, status: 503}) == :transient
      assert Failure.classify(%{__exception__: true, status: 408}) == :transient
      assert Failure.classify(%{__exception__: true, status: 422}) == :bug
    end

    test "reads a status nested under an error's reason" do
      assert Failure.classify(%{__exception__: true, reason: %{status: 500}}) == :transient
    end

    test "falls back to the error's own name when it carries no status" do
      assert Failure.classify(%Mint.TransportError{reason: :closed}) == :transient
    end

    test "reads an error by the cause it carries, then by its name" do
      stream = &ReqLLM.Error.API.Stream.exception(reason: "Stream failed", cause: &1)

      assert Failure.classify(stream.(:timeout)) == :transient
      assert Failure.classify(stream.(:interrupted)) == :ceiling
      assert Failure.classify(stream.(:something_new)) == :bug

      assert Failure.classify(%Mint.TransportError{reason: :closed} |> Map.put(:cause, :odd)) ==
               :transient
    end
  end

  describe "retryable?/1" do
    test "is true only for a transient failure" do
      assert Failure.retryable?(:timeout)
      refute Failure.retryable?(:interrupted)
      refute Failure.retryable?(:anything_else)
    end
  end
end
