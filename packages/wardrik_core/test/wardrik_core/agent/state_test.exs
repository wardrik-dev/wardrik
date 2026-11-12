defmodule WardrikCore.Agent.StateTest do
  use ExUnit.Case, async: true

  alias WardrikCore.Agent.State

  describe "new/1" do
    test "creates a new state struct with the given options" do
      opts = [agent_id: "agent_1", model: "moonshotai:kimi-k3", state: :idle]
      state = State.new(opts)

      assert %State{} = state
      assert state.agent_id == "agent_1"
      assert state.model == "moonshotai:kimi-k3"
      assert state.state == :idle
    end

    test "raises an error if the model is not valid" do
      opts = [agent_id: "agent_1", model: "invalid-model", state: :idle]

      assert_raise ArgumentError, fn ->
        State.new(opts)
      end
    end
  end

  describe "dump/1 and load/1" do
    setup do
      context = WardrikCore.Context.new(agent_id: "agent_1", middleware: [])

      state =
        State.new(agent_id: "agent_1", model: "moonshotai:kimi-k3", context: context)
        |> Map.put(:task, Task.async(fn -> :ok end))
        |> Map.put(:state, :running)

      %{state: state}
    end

    test "returns a plain map with no processes, refs or functions", %{state: state} do
      dumped = State.dump(state)

      refute is_struct(dumped)
      refute Map.has_key?(dumped, :task)
      assert dumped.model == "moonshotai:kimi-k3"
      assert serializable?(dumped)
    end

    test "a running turn comes back idle with its messages queued first", %{state: state} do
      state = %{state | in_flight: [:taken], pending_messages: [:queued]}

      assert %State{state: :idle, task: nil, in_flight: [], pending_messages: [:taken, :queued]} =
               state |> State.dump() |> State.load()
    end

    test "a parked turn round trips", %{state: state} do
      parked = %{reason: {:tool_calls, []}, messages: [:asked]}
      state = %{state | state: :waiting, parked: parked, in_flight: [:taken]}

      assert %State{state: :waiting, in_flight: [:taken], parked: ^parked} =
               state |> State.dump() |> State.load()
    end

    test "a resumed turn comes back waiting on the same calls", %{state: state} do
      parked = %{reason: {:tool_calls, []}, messages: [:asked]}
      state = %{state | parked: parked, in_flight: [:taken], pending_messages: [:queued]}

      assert %State{state: :waiting, in_flight: [:taken], pending_messages: [:queued]} =
               state |> State.dump() |> State.load()
    end

    test "a turn that checkpointed a batch comes back due to recover it", %{state: state} do
      checkpoint = %{messages: [:asked], calls: [], rounds: 3}
      state = %{state | checkpoint: checkpoint, in_flight: [:taken], pending_messages: [:queued]}

      assert %State{
               state: :due,
               checkpoint: ^checkpoint,
               in_flight: [:taken],
               pending_messages: [:queued]
             } = state |> State.dump() |> State.load()
    end

    test "loads a state saved with fields that have since been removed", %{state: state} do
      dumped = State.dump(state)
      dumped = %{dumped | context: Map.put(dumped.context, :removed_field, true)}

      assert %State{context: %WardrikCore.Context{}} = State.load(dumped)
    end

    test "loads a state whose model no longer resolves", %{state: state} do
      dumped = %{State.dump(state) | model: "gone:model"}

      assert %State{model: "gone:model"} = State.load(dumped)
    end

    test "round trips the model and context", %{state: state} do
      loaded = state |> State.dump() |> State.load()

      assert loaded.model == state.model
      assert loaded.context.agent_id == "agent_1"
      assert loaded.context.middleware == []
    end
  end

  defp serializable?(term) when is_pid(term) or is_reference(term) or is_function(term),
    do: false

  defp serializable?(term) when is_port(term), do: false
  defp serializable?(term) when is_map(term), do: Enum.all?(term, &serializable?/1)
  defp serializable?(term) when is_list(term), do: Enum.all?(term, &serializable?/1)

  defp serializable?(term) when is_tuple(term),
    do: term |> Tuple.to_list() |> serializable?()

  defp serializable?(_term), do: true

  describe "next_batch/1" do
    test "takes the messages in a row from one principal" do
      maria = message("a", "user:maria")
      again = message("b", "user:maria")
      jon = message("c", "user:jon")
      later = message("d", "user:maria")

      assert {[^maria, ^again], [^jon, ^later]} = State.next_batch([maria, again, jon, later])
    end

    test "keeps messages no one signed together" do
      assert {[_, _], []} = State.next_batch([message("a", nil), message("b", nil)])
    end
  end

  defp message(text, nil), do: ReqLLM.Context.user(text, %{})

  defp message(text, id),
    do: ReqLLM.Context.user(text, %{principal: %WardrikCore.Principal{id: id}})
end
