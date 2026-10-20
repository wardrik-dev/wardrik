defmodule Wardrik.WaitTest do
  use ExUnit.Case, async: true

  alias Wardrik.Conversation.Assistant
  alias Wardrik.Conversation.ToolCall
  alias Wardrik.Error
  alias Wardrik.LLM.Turn
  alias Wardrik.Principal
  alias Wardrik.Reply
  alias Wardrik.Resource
  alias Wardrik.Role
  alias Wardrik.Scope
  alias Wardrik.Test.AgentRunners
  alias Wardrik.Test.Fleet
  alias Wardrik.Test.Script
  alias Wardrik.Token
  alias Wardrik.Waiting

  @shipped {:ok, [Assistant.new("Shipped.")]}

  defp scope(roles \\ [:owner]) do
    token = %Token{
      principal: Principal.new("acme/@jon", name: "Jon"),
      scope: [Role.bind(roles, [Resource.parse!("test/agent/*")])]
    }

    Scope.new(Wardrik.Test.host(), token)
  end

  defp agent(run, opts \\ []) do
    {resume, opts} = Keyword.split(opts, [:resume])
    {id, _pid} = Fleet.start_agent([config: Script.new(run, resume)] ++ opts)
    id
  end

  @doc "Waits on two calls to `deploy`, so a decision on one leaves the other waiting."
  def parking_two(%Turn{run: run}) do
    turn = AgentRunners.parked_turn("call_1")

    calls =
      for id <- ["call_1", "call_2"],
          do: AgentRunners.waiting(%ToolCall{id: id, name: "deploy", arguments: %{}}, "Ship?")

    Turn.under(%{turn | calls: calls}, run)
  end

  @doc "Carries on waiting on the calls `decisions` leave, and answers once none are left."
  def deciding(%Turn{calls: calls} = turn, decisions) do
    case Enum.reject(calls, &Map.has_key?(decisions, &1.id)) do
      [] -> Turn.done(%{turn | state: :running}, [Assistant.new("Shipped.")])
      left -> Turn.under(%{turn | calls: left}, turn.run)
    end
  end

  describe "asking with wait:" do
    test "answers the agent's reply once its run completes" do
      agent = agent({AgentRunners, :echo, [self(), "Order 1001 left on Monday."]})

      assert {:ok, %Reply{agent: ^agent, text: "Order 1001 left on Monday."} = reply} =
               Wardrik.agent_ask(scope(), agent, "Where is order 1001?", wait: 5_000)

      assert [%{"role" => "assistant"}] = reply.messages
      resources = [Wardrik.AgentAddress.resource(agent)]
      assert {:ok, events} = Wardrik.events(scope(), resources: resources, after: reply.cursor)
      assert Enum.to_list(events) == []
    end

    test "answers the calls its run waits on, and carries on once they are decided" do
      agent =
        agent({AgentRunners, :parking, [self(), "call_1"]},
          resume: {AgentRunners, :resuming, [self(), @shipped]}
        )

      assert {:waiting, %Waiting{run: run, calls: [call]}} =
               Wardrik.agent_ask(scope(), agent, "Ship it", wait: 5_000)

      assert %{id: "call_1", reason: :tool_approval, name: "deploy", message: _prompt} = call

      assert {:ok, %Reply{run: ^run, text: "Shipped."}} =
               Wardrik.agent_approve(scope(), agent, "call_1", wait: 5_000)
    end

    test "answers the calls a decision leaves waiting" do
      agent =
        agent({__MODULE__, :parking_two, []}, resume: {__MODULE__, :deciding, []})

      assert {:waiting, %Waiting{run: run, calls: [_one, _two]}} =
               Wardrik.agent_ask(scope(), agent, "Ship both", wait: 5_000)

      assert {:waiting, %Waiting{run: ^run, calls: [%{id: "call_2"}]}} =
               Wardrik.agent_deny(scope(), agent, "call_1", wait: 5_000)

      assert %Reply{text: "Shipped."} =
               Wardrik.agent_approve!(scope(), agent, "call_2", wait: 5_000)
    end

    test "answers a run that fails, or is stopped, as an error" do
      agent = agent({AgentRunners, :failing, [:no_model]})

      assert {:error, %Error{type: :failed, details: %{"error" => %{"message" => _why}}}} =
               Wardrik.agent_ask(scope(), agent, "Hi", wait: 5_000)

      agent = agent({AgentRunners, :blocking, [self(), "ok"]}, grace: 10)
      waiting = Task.async(fn -> Wardrik.agent_ask(scope(), agent, "Hi", wait: 5_000) end)
      assert_receive {:turn, _messages, _turn}
      assert :ok = Wardrik.agent_cancel(scope(), agent)

      assert {:error, %Error{type: :cancelled}} = Task.await(waiting)
    end

    test "stops waiting after its time, and the agent carries on" do
      agent = agent({AgentRunners, :blocking, [self(), "Done."]})

      assert {:error, %Error{type: :timeout}} = Wardrik.agent_ask(scope(), agent, "Hi", wait: 50)
      assert_receive {:turn, _messages, turn}
      send(turn, :release)

      Fleet.await_update(fn ->
        Wardrik.Fleet.lookup(agent, host: Wardrik.Test.host()).status == :idle
      end)

      assert {:ok, %{history: history}} = Wardrik.agent_read(scope(), agent)
      assert Wardrik.Conversation.text(List.last(history.messages)) == "Done."
    end

    test "needs agent.events on the agent, and sends nothing without it" do
      agent = agent({AgentRunners, :echo, [self(), "ok"]})

      assert {:error, %Error{type: :forbidden}} =
               Wardrik.agent_ask(scope([:messenger]), agent, "Hi", wait: 5_000)

      assert {:ok, %{history: %{messages: []}}} = Wardrik.agent_read(scope(), agent)
    end
  end
end
