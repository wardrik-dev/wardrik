defmodule Wardrik.RetriesTest do
  use ExUnit.Case, async: true

  alias Wardrik.Retries
  alias WardrikCore.Context
  alias WardrikCore.Resume
  alias WardrikPolicy.Ask

  @timeout %ReqLLM.Error.API.Stream{reason: "Stream failed: :timeout", cause: :timeout}
  @opts [max_wait: 0]

  setup context do
    test = self()

    :telemetry.attach(
      context.test,
      [:wardrik, :message, :retrying],
      fn _name, _measurements, metadata, _config -> send(test, {:retrying, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(context.test) end)
    :ok
  end

  defp generate(fields \\ []) do
    struct!(
      Context.new(agent_id: "acme/triage", step: :generate, span: WardrikCore.Span.root()),
      fields
    )
  end

  defp failing(failures) do
    {:ok, left} = Agent.start_link(fn -> failures end)

    fn context ->
      answered(context, Agent.get_and_update(left, fn [next | rest] -> {next, rest} end))
    end
  end

  defp answered(context, :ok), do: {:ok, %{context | response: :answered}}
  defp answered(_context, reason), do: {:error, reason}

  test "tries a failed model call again until it answers, and says so each time" do
    assert {:ok, %{response: :answered}} =
             Retries.call(generate(), failing([@timeout, @timeout, :ok]), @opts)

    assert_receive {:retrying, %{attempt: 1, attempts: 6, wait_ms: 0, error: error}}
    assert error == %{type: "Stream", message: "Stream failed: :timeout"}
    assert_receive {:retrying, %{attempt: 2}}
    refute_received {:retrying, _metadata}
  end

  test "doesn't try again what can't succeed as it is, or what a policy refused" do
    hopeless = %ReqLLM.Error.API.Request{reason: "bad", status: 400}
    assert {:error, ^hopeless} = Retries.call(generate(), failing([hopeless, :ok]), @opts)

    limited = %ReqLLM.Error.API.Request{reason: "slow down", status: 429}
    assert {:ok, _context} = Retries.call(generate(), failing([limited, :ok]), @opts)

    assert {:error, "Over budget."} =
             Retries.call(generate(), failing(["Over budget.", :ok]), @opts)

    refute_received {:retrying, %{error: %{message: "Over budget."}}}
    assert {:ok, _context} = Retries.call(generate(), failing([:timeout, :ok]), @opts)
  end

  test "asks a person once the tries are spent, and tries afresh once they approve" do
    assert {:park, %Ask{interrupt: "model_approval", message: message}, _context} =
             Retries.call(generate(), failing([@timeout, @timeout, @timeout]),
               attempts: 2,
               max_wait: 0
             )

    assert message == "The model failed 3 times: Stream failed: :timeout. Try again?"

    approved = %Resume{
      reason: %Ask{interrupt: "model_approval", message: message},
      input: %{"model" => :approve}
    }

    assert {:ok, _context} =
             Retries.call(generate(resume: approved), failing([@timeout, :ok]),
               attempts: 2,
               max_wait: 0
             )

    denied = %{approved | input: %{"model" => {:deny, "Leave it."}}}
    assert {:error, "Leave it."} = Retries.call(generate(resume: denied), failing([:ok]), @opts)
  end

  test "fails the turn once the tries are spent where told to, and passes other steps by" do
    assert {:error, @timeout} =
             Retries.call(generate(), failing([@timeout, @timeout]),
               attempts: 1,
               max_wait: 0,
               on_exhausted: :fail
             )

    assert {:ok, :passed} =
             Retries.call(%Context{step: :turn}, fn _context -> {:ok, :passed} end, @opts)
  end
end
