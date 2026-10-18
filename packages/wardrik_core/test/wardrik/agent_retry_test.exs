defmodule Wardrik.AgentRetryTest do
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Wardrik.Agent
  alias Wardrik.Event
  alias Wardrik.LLM.Retry.Backoff
  alias Wardrik.Test.LLMStub

  setup :set_mimic_global

  test "a turn whose model call keeps failing parks for a person, and goes on once approved" do
    key = Wardrik.Test.Fleet.id("retry")
    {^key, agent} = Wardrik.Test.Fleet.start_agent([retry: %Backoff{attempts: 0}], key)
    :ok = Event.Bus.subscribe(key)
    stub(ReqLLM, :stream_text, fn _model, _context, _opts -> {:error, :timeout} end)

    capture_log(fn ->
      Agent.ask(agent, "Reconcile last week.")

      assert_receive %Event{
                       payload: %Event.TurnParked{
                         calls: [
                           {%{name: "model"}, "The model failed once: :timeout. Try again?"}
                         ]
                       }
                     },
                     5_000
    end)

    assert [{%{id: id, name: "model"}, _prompt}] = Agent.parked(agent)

    LLMStub.stream([LLMStub.final_answer("Reconciled.")])
    :ok = Agent.resume(agent, %{id => :approve})

    assert_receive %Event{payload: %Event.TurnFinished{}}, 5_000
    assert Agent.parked(agent) == []
  end
end
