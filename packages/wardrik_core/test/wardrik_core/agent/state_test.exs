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

    test "takes the name of one of its context's endpoints as its model" do
      endpoint = [model: "openai:gpt-4o-mini", base_url: "http://localhost:9931/v1"]
      context = Wardrik.Context.new(agent_id: "agent_1", endpoints: %{"local" => endpoint})

      state = State.new(agent_id: "agent_1", model: "local", context: context)

      assert state.model == "local"
    end
  end

  describe "canonical_endpoints!/1" do
    test "names each endpoint by string and checks its model and base_url" do
      endpoints = %{local: [model: "openai:gpt-4o-mini", base_url: "http://localhost:9931/v1"]}

      assert %{"local" => [model: "openai:gpt-4o-mini", base_url: "http://localhost:9931/v1"]} =
               State.canonical_endpoints!(endpoints)

      assert_raise NimbleOptions.ValidationError, fn ->
        State.canonical_endpoints!(%{"local" => [model: "openai:gpt-4o-mini"]})
      end

      assert_raise ArgumentError, fn ->
        State.canonical_endpoints!(%{"local" => [model: "unnamed", base_url: "http://x/v1"]})
      end
    end
  end

  describe "dump/1 and load/1" do
    alias ReqLLM.Message.ContentPart
    alias Wardrik.ToolCall
    alias WardrikCore.Test.NeedsApproval
    alias WardrikCore.Test.ParkTools

    setup do
      context = Wardrik.Context.new(agent_id: "agent_1", middleware: [ParkTools])

      state =
        [agent_id: "agent_1", model: "moonshotai:kimi-k3", context: context]
        |> State.new()
        |> Map.put(:task, Task.async(fn -> :ok end))
        |> Map.put(:state, :running)

      %{state: state}
    end

    defp kept(state, settings \\ [middleware: [ParkTools]]) do
      state
      |> State.dump()
      |> JSON.encode!()
      |> JSON.decode!()
      |> State.load()
      |> State.configure(settings)
    end

    defp asked(text), do: ReqLLM.Context.user(text, %{id: "msg_" <> text})

    test "keeps the state as JSON, without how the agent is configured", %{state: state} do
      state = put_in(state.context.instructions, "Be brief.")
      dumped = State.dump(state)

      encoded = JSON.encode!(dumped)
      assert JSON.decode!(encoded) == dumped
      assert dumped["model"] == "moonshotai:kimi-k3"
      refute JSON.encode!(dumped) =~ "Be brief."

      loaded = State.load(dumped)
      assert loaded.context == nil
      refute State.ready?(loaded)

      configured = State.configure(loaded, instructions: "Be brief.", middleware: [ParkTools])
      assert State.ready?(configured)
      assert configured.context.instructions == "Be brief."
    end

    test "a running turn comes back idle with its messages queued first", %{state: state} do
      state = %{state | in_flight: [asked("taken")], pending_messages: [asked("queued")]}

      assert %State{state: :idle, task: nil, in_flight: [], pending_messages: pending} =
               kept(state)

      assert Enum.map(pending, & &1.metadata.id) == ["msg_taken", "msg_queued"]
    end

    test "a parked turn round trips, with what its calls answered as the model saw it",
         %{state: state} do
      parked = %{
        reason:
          {:tool_calls,
           [
             {%ToolCall{id: "1", name: "pay", arguments: %{"usd" => 5}},
              {:park, %NeedsApproval{}}},
             {%ToolCall{id: "2", name: "look"}, {:ok, %{found: [:it]}}},
             {%ToolCall{id: "3", name: "fail"}, {:error, {:exit, :timeout}}}
           ]},
        messages: [asked("pay")],
        metadata: %{},
        span: WardrikCore.Span.root(),
        measurements: %{usd: 0.25}
      }

      state = %{state | state: :waiting, parked: parked, in_flight: [asked("pay")]}

      assert %State{state: :waiting, parked: loaded} = kept(state)

      assert loaded.reason ==
               {:tool_calls,
                [
                  {%ToolCall{id: "1", name: "pay", arguments: %{"usd" => 5}},
                   {:park, %NeedsApproval{}}},
                  {%ToolCall{id: "2", name: "look"}, {:ok, %{"found" => ["it"]}}},
                  {%ToolCall{id: "3", name: "fail"},
                   {:error, "The call ran out of time, so it was stopped."}}
                ]}

      assert %{parked | reason: loaded.reason} == loaded
    end

    test "a resumed turn comes back waiting on the same calls", %{state: state} do
      parked = %{reason: :in_doubt, messages: [], metadata: %{}, span: nil, measurements: %{}}
      state = %{state | parked: parked, in_flight: [asked("taken")]}

      assert %State{
               state: :waiting,
               in_flight: [%{metadata: %{id: "msg_taken"}}],
               parked: ^parked
             } =
               kept(state)
    end

    test "a turn that checkpointed a batch comes back due to recover it", %{state: state} do
      checkpoint = %{
        messages: [asked("asked")],
        calls: [%ToolCall{id: "1", name: "look", arguments: %{}}],
        rounds: :infinity,
        metadata: %{},
        private: %{},
        span: WardrikCore.Span.root(),
        measurements: %{}
      }

      assert %State{state: :due, checkpoint: ^checkpoint} =
               kept(%{state | checkpoint: checkpoint})
    end

    test "keeps a state whose model no longer resolves", %{state: state} do
      assert %State{model: "gone:model"} = kept(%{state | model: "gone:model"})
    end

    test "keeps what it can't read as it was, and says why", %{state: state} do
      parked = %{
        reason: %NeedsApproval{},
        messages: [],
        metadata: %{},
        span: nil,
        measurements: %{}
      }

      dumped = State.dump(%{state | state: :waiting, parked: parked})

      unread =
        dumped
        |> State.load()
        |> State.configure(middleware: [])

      refute State.ready?(unread)
      assert State.unreadable(unread) =~ "test_needs_approval"
      assert State.dump(unread) == dumped
    end

    test "keeps a state it can't read as it was, whatever it holds", %{state: state} do
      dumped = State.dump(%{state | pending_messages: [asked("queued")]})
      [message] = dumped["pending"]

      broken = [
        %{dumped | "state" => "dancing"},
        %{dumped | "pending" => [%{message | "parts" => [%{"type" => "hologram"}]}]},
        %{dumped | "pending" => [%{message | "metadata" => %{"sent_at" => "yesterday"}}]},
        %{
          dumped
          | "pending" => [
              %{
                message
                | "parts" => [
                    %{"type" => "blob", "modality" => "image", "data" => %{"$bytes" => "%%"}}
                  ]
              }
            ]
        },
        %{dumped | "pending" => "none"},
        Map.delete(dumped, "agent_id"),
        "not a state"
      ]

      for json <- broken do
        loaded =
          json
          |> State.load()
          |> State.configure(middleware: [ParkTools])

        assert State.unreadable(loaded), "read #{inspect(json)}"
        assert State.dump(loaded) == json
      end
    end

    test "can't read what two formats both claim", %{state: state} do
      dumped = State.dump(state)

      loaded =
        dumped
        |> State.load()
        |> State.configure(middleware: [ParkTools, WardrikCore.Test.Twin])

      assert State.unreadable(loaded) =~ "test_needs_approval"
    end

    test "keeps messages as the model is sent them" do
      principal = %Wardrik.Principal{id: "user:maria", attributes: %{"team" => "ops"}}

      messages = [
        ReqLLM.Context.user("hi", %{
          id: "msg_1",
          sent_at: ~U[2026-11-13 12:00:00Z],
          principal: principal,
          labels: ["outside"]
        }),
        %ReqLLM.Message{
          role: :assistant,
          content: [
            %ContentPart{type: :thinking, text: "Hmm.", metadata: %{thought_signature: "sig=="}},
            %ContentPart{type: :text, text: "Looking."},
            %ContentPart{type: :image, data: <<137, 80, 78, 71, 0, 255>>, media_type: "image/png"}
          ],
          tool_calls: [ReqLLM.ToolCall.new("call_1", "look", ~s({"q":"x"}))],
          reasoning_details: [
            %ReqLLM.Message.ReasoningDetails{text: "Hmm.", signature: "s", provider: :anthropic}
          ],
          metadata: %{provider: :anthropic}
        },
        ReqLLM.Context.tool_result("call_1", "look", "found")
      ]

      json =
        messages
        |> WardrikCore.Stored.Message.dump()
        |> JSON.encode!()
        |> JSON.decode!()

      assert WardrikCore.Stored.Message.loaded(json) == messages
    end
  end

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
    do: ReqLLM.Context.user(text, %{principal: %Wardrik.Principal{id: id}})
end
