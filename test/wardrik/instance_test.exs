defmodule Wardrik.InstanceTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM

  alias Wardrik.Test.Instance

  setup :set_mimic_global

  setup do
    stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
    stub(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, answer("Done.")} end)
    :ok
  end

  test "starts as a module, is reached by its name, and sends kept events to its sinks" do
    start_supervised!(
      {Instance,
       sinks: [{Wardrik.Test.Sunk, test: self()}],
       listeners: [{Wardrik.Test.Runs, test: self(), agents: ["me/assistant"]}]}
    )

    assert %Wardrik{deployment: "from-init"} = Wardrik.Instance.fetch!(Instance)

    me = Instance.as("me")
    assert %Wardrik.Scope{wardrik: Instance} = me

    {:ok, agent} = Wardrik.Agent.define(me, "me/assistant", model: "anthropic:claude-haiku-4-5")
    assert {:ok, %Wardrik.Reply{text: _text}} = Wardrik.Agent.reply(me, agent, "Hi")

    assert_receive {:sunk, %Wardrik.Event{type: "wardrik.run.completed", agent: "me/assistant"}},
                   1000

    assert_receive {:handled, %Wardrik.Event{type: "wardrik.run.completed"},
                    %Wardrik.Listener{cursor: cursor}},
                   1000

    assert is_binary(cursor)
    refute_received {:sunk, %Wardrik.Event{type: "wardrik.message.delta"}}
  end

  test "follows only the agents a listener names, by their exact IDs" do
    start_supervised!(
      {Instance, listeners: [{Wardrik.Test.Runs, test: self(), agents: ["me/elsewhere"]}]}
    )

    me = Instance.as("me")
    {:ok, agent} = Wardrik.Agent.define(me, "me/assistant", model: "anthropic:claude-haiku-4-5")
    assert {:ok, %Wardrik.Reply{}} = Wardrik.Agent.reply(me, agent, "Hi")

    refute_receive {:handled, _event, _listener}, 200
  end

  test "takes its options as it starts, over its config" do
    start_supervised!({Instance, deployment: "given"})
    assert %Wardrik{deployment: "given"} = Wardrik.Instance.fetch!(Instance)
  end

  test "says which Wardrik a listener follows isn't started" do
    assert {:error, {{:EXIT, {%ArgumentError{message: message}, _stack}}, _child}} =
             start_supervised(
               {Wardrik.Test.Runs,
                wardrik: Nowhere.Wardrik, agents: ["me/assistant"], test: self()}
             )

    assert message =~ "Nowhere.Wardrik isn't started"
  end
end
