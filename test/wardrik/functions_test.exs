defmodule Wardrik.FunctionsTest do
  use ExUnit.Case, async: false
  use Mimic

  import Wardrik.Test.LLM
  import Wardrik.Test.Wardrik

  describe "running" do
    setup :set_mimic_global
    setup :start_wardrik

    setup %{wardrik: wardrik} do
      stub(ReqLLM.StreamResponse, :process_stream, fn response, _opts -> {:ok, response} end)
      stub(ReqLLM, :stream_text, fn _model, _messages, _opts -> {:ok, answer("Nothing.")} end)
      :ok = WardrikEvents.subscribe(Wardrik.events(wardrik), ["*"])
      start_agent(wardrik, "acme/triage")
      %{scope: owner(wardrik)}
    end

    test "runs the operation, and answers in structs", %{scope: scope} do
      assert {:ok, cursor} = Wardrik.Events.head(scope)

      assert {:ok, %Wardrik.Message{id: "msg_1", cursor: _cursor}} =
               Wardrik.Agent.ask(scope, "acme/triage", content: "Hi", id: "msg_1")

      until("wardrik.run.completed")

      assert {:ok,
              %Wardrik.Agent{id: "acme/triage", status: :idle, activity: %Wardrik.Activity{}}} =
               Wardrik.Agent.read(scope, "acme/triage")

      assert {:ok, [%Wardrik.Agent{id: "acme/triage", status: :idle}]} =
               Wardrik.Agents.list(scope)

      assert {:ok, []} = Wardrik.Interrupts.list(scope)
      assert {:ok, %Wardrik.Page{events: [], next: 0}} = Wardrik.Audit.list(scope, limit: 1)

      assert {:ok, %Wardrik.Timeline{items: [%{"kind" => "user"}, %{"kind" => "run"}]}} =
               Wardrik.Agent.timeline(scope, "acme/triage")

      assert {:ok, %Wardrik.Runs{runs: [%Wardrik.Run{status: :completed}]}} =
               Wardrik.Agent.runs(scope, "acme/triage")

      assert {:ok, stream} =
               Wardrik.Events.stream_list(scope, after: cursor, types: ["wardrik.run.completed"])

      assert [{%Wardrik.Event{type: "wardrik.run.completed", time: %DateTime{}}, _cursor}] =
               Enum.take(stream, 1)

      assert :ok = Wardrik.Agent.cancel(scope, "acme/triage")
      assert {:ok, %Wardrik.Message{}} = Wardrik.Agent.ask(scope, "acme/triage", "Hi again")
    end

    test "takes path parameters over the same ones in input", %{scope: scope} do
      assert {:error, %Wardrik.Error{type: :not_found}} =
               Wardrik.Agent.read(scope, "acme/missing", agent: "acme/triage")
    end
  end
end
