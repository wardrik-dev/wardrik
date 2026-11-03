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
    start_supervised!({Instance, sinks: [{Wardrik.Test.Sunk, self()}]})

    assert %Wardrik{deployment: "from-init"} = Wardrik.Instance.fetch!(Instance)

    me = Instance.as("me")
    assert %Wardrik.Scope{wardrik: Instance} = me

    {:ok, agent} = Wardrik.Agent.define(me, "me/assistant", model: "anthropic:claude-haiku-4-5")
    assert {:ok, %Wardrik.Reply{text: _text}} = Wardrik.Agent.reply(me, agent, "Hi")

    assert_receive {:sunk, %{"type" => "wardrik.run.completed", "agent" => "me/assistant"}}, 1000
    refute_received {:sunk, %{"type" => "wardrik.message.delta"}}
  end

  test "takes its options as it starts, over its config" do
    start_supervised!({Instance, deployment: "given"})
    assert %Wardrik{deployment: "given"} = Wardrik.Instance.fetch!(Instance)
  end
end
