defmodule Wardrik.Event.LogTest do
  use ExUnit.Case, async: true

  import Wardrik.Test, only: [store: 0]
  use Mimic

  alias Wardrik.Bus
  alias Wardrik.Bus.Source
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Event.Log.Writer
  alias Wardrik.Test.EventLog

  setup :verify_on_exit!

  setup do
    agent_id = Wardrik.Test.Fleet.id("log")
    :ok = Log.subscribe(agent_id)

    %{agent_id: agent_id, source: Source.root(agent_id, name: "turn")}
  end

  defp started(agent_id),
    do:
      Bus.Event.new(Source.root(agent_id), %Bus.AgentStarted{
        node: node(),
        status: :idle,
        generation: "g1"
      })

  defp open(agent_id, head \\ 0),
    do: Writer.open(store(), Writer.new(agent_id, head), started(agent_id))

  defp append!(writer, source, payload) do
    {:ok, writer} = Writer.append(store(), writer, Bus.Event.new(source, payload))
    writer
  end

  defp sequences(agent_id, starting_after \\ 0) do
    {:ok, events} = Log.read(store(), agent_id, starting_after: starting_after)
    Enum.map(events, &String.to_integer(&1["sequence"]))
  end

  defp days_ago(days),
    do: System.system_time(:microsecond) - days * 24 * 60 * 60 * 1_000_000

  describe "writing" do
    test "numbers each durable event from 1, writes it, then delivers it", %{
      agent_id: agent_id,
      source: source
    } do
      agent_id |> open() |> append!(source, %Bus.TurnStarted{messages: []})

      assert {:ok,
              [
                %{"type" => "wardrik.agent.started", "sequence" => "000000000001"},
                %{"type" => "wardrik.run.started", "sequence" => "000000000002"}
              ]} = Log.read(store(), agent_id)

      assert_receive %Entry{sequence: 1, follows: 0, event: %{"type" => "wardrik.agent.started"}}
      assert_receive %Entry{sequence: 2, follows: 1, event: %{"type" => "wardrik.run.started"}}
    end

    test "delivers live events without writing them, a delta under the message its call opened",
         %{agent_id: agent_id, source: source} do
      agent_id
      |> open()
      |> append!(
        source,
        %Bus.ModelStarted{
          message_id: "s1.m0",
          model_spec: "anthropic:claude-sonnet-5",
          decided_by: %{by: :default, hooks: []}
        }
      )
      |> append!(source, %Bus.ToolCall{
        call: %Wardrik.Conversation.ToolCall{id: "call_1", name: "search", arguments: %{}}
      })
      |> append!(source, %Bus.Thinking{text: "hmm"})
      |> append!(source, %Bus.Result{text: "Hel"})
      |> append!(source, %Bus.ToolProgress{
        call_id: "call_1",
        name: "search",
        progress: 1,
        total: 2
      })
      |> append!(source, %Bus.ModelFinished{
        message_id: "s1.m0",
        outcome: :ok,
        duration_ms: 5,
        answer: nil,
        cost: nil
      })
      |> append!(source, %Bus.Result{text: "lo"})

      assert EventLog.types(agent_id) == [
               "wardrik.agent.started",
               "wardrik.message.started",
               "wardrik.message.completed"
             ]

      assert_receive %Entry{sequence: 1}
      assert_receive %Entry{sequence: 2, event: %{"type" => "wardrik.message.started"}}

      assert_receive %Entry{
        sequence: nil,
        follows: 2,
        event: %{
          "type" => "wardrik.reasoning.delta",
          "data" => %{"message" => %{"id" => "s1.m0"}}
        }
      }

      assert_receive %Entry{
        sequence: nil,
        event: %{"type" => "wardrik.message.delta", "data" => %{"delta" => "Hel"}}
      }

      assert_receive %Entry{sequence: nil, event: %{"type" => "wardrik.tool_call.progress"}}
      assert_receive %Entry{sequence: 3, event: %{"type" => "wardrik.message.completed"}}
      refute_received %Entry{}
    end

    test "stops delivering to a subscriber that leaves", %{agent_id: agent_id, source: source} do
      writer = open(agent_id)
      assert_receive %Entry{sequence: 1}

      :ok = Log.unsubscribe(agent_id)
      append!(writer, source, %Bus.TurnStarted{messages: []})

      refute_received %Entry{}
    end

    test "an entry says whether it comes after the log read through a number", %{
      agent_id: agent_id
    } do
      live = %Entry{log: agent_id, event: %{}, follows: 4}
      durable = %Entry{log: agent_id, event: %{}, sequence: 4, follows: 3}

      assert Entry.follows?(live, 4)
      refute Entry.follows?(live, 5)
      assert Entry.follows?(durable, 3)
      refute Entry.follows?(durable, 4)
    end

    test "writes an event appended ahead of the bus once", %{agent_id: agent_id, source: source} do
      decided =
        Bus.Event.new(source, %Bus.CallDecided{call_id: "call_1", decision: :approve, by: nil})

      {:ok, writer} = Writer.append_ahead(store(), open(agent_id), decided)
      {:ok, _writer} = Writer.append(store(), writer, decided)

      assert EventLog.types(agent_id) == ["wardrik.agent.started", "wardrik.interrupt.resolved"]
    end
  end

  describe "owners" do
    test "an owner goes on from the last number written, whatever it was told", %{
      agent_id: agent_id,
      source: source
    } do
      Enum.reduce(1..20, open(agent_id), fn _n, writer ->
        append!(writer, source, %Bus.TurnStarted{messages: []})
      end)

      open(agent_id)
      open(agent_id, 7)

      assert sequences(agent_id) == Enum.to_list(1..23)
      assert Enum.count(EventLog.types(agent_id), &(&1 == "wardrik.agent.started")) == 3
    end

    test "the owner replaced stops writing", %{agent_id: agent_id, source: source} do
      first = open(agent_id)
      second = open(agent_id)

      assert {:error, :fenced, first} =
               Writer.append(
                 store(),
                 first,
                 Bus.Event.new(source, %Bus.TurnStarted{messages: []})
               )

      assert {:error, :fenced, _first} =
               Writer.append(store(), first, Bus.Event.new(source, %Bus.Result{text: "x"}))

      append!(second, source, %Bus.TurnResumed{decisions: %{}})

      assert EventLog.types(agent_id) == [
               "wardrik.agent.started",
               "wardrik.agent.started",
               "wardrik.run.resumed"
             ]
    end

    test "an owner that finds one before it still writing moves past it", %{agent_id: agent_id} do
      expect(WardrikStore, :put, fn store, ns, key, event, opts ->
        {:ok, _vsn} =
          call_original(WardrikStore, :put, [store, ns, key, %{event | "id" => "old"}, opts])

        {:error, :conflict}
      end)

      open(agent_id)

      assert {:ok, [%{"id" => "old"}, %{"type" => "wardrik.agent.started"}]} =
               Log.read(store(), agent_id)
    end

    test "a write the store made without confirming it is taken as its own", %{
      agent_id: agent_id,
      source: source
    } do
      writer = open(agent_id)

      expect(WardrikStore, :put, fn store, ns, key, event, opts ->
        {:ok, _vsn} = call_original(WardrikStore, :put, [store, ns, key, event, opts])
        {:error, :unavailable}
      end)

      assert {:error, :unavailable, writer} =
               Writer.append(
                 store(),
                 writer,
                 Bus.Event.new(source, %Bus.TurnStarted{messages: []})
               )

      append!(writer, source, %Bus.TurnResumed{decisions: %{}})

      assert EventLog.types(agent_id) == [
               "wardrik.agent.started",
               "wardrik.run.started",
               "wardrik.run.resumed"
             ]
    end

    test "an owner that could not write its start writes it when it comes from the bus", %{
      agent_id: agent_id
    } do
      started = started(agent_id)

      expect(WardrikStore, :put, fn _store, _ns, _key, _event, _opts -> {:error, :unavailable} end)

      writer = Writer.open(store(), Writer.new(agent_id), started)
      assert {:ok, []} = Log.read(store(), agent_id)

      assert {:ok, _writer} = Writer.append(store(), writer, started)
      assert EventLog.types(agent_id) == ["wardrik.agent.started"]
    end

    test "a write the store failed leaves its number to the next", %{
      agent_id: agent_id,
      source: source
    } do
      writer = open(agent_id)

      expect(WardrikStore, :put, fn _store, _ns, _key, _event, _opts -> {:error, :unavailable} end)

      assert {:error, :unavailable, writer} =
               Writer.append(
                 store(),
                 writer,
                 Bus.Event.new(source, %Bus.TurnStarted{messages: []})
               )

      append!(writer, source, %Bus.TurnResumed{decisions: %{}})

      assert EventLog.types(agent_id) == ["wardrik.agent.started", "wardrik.run.resumed"]
      assert sequences(agent_id) == [1, 2]
    end
  end

  describe "reading" do
    test "answers the events after a number, as many as asked", %{
      agent_id: agent_id,
      source: source
    } do
      Enum.reduce(1..4, open(agent_id), fn _n, writer ->
        append!(writer, source, %Bus.TurnStarted{messages: []})
      end)

      assert {:ok, [%{"sequence" => "000000000003"}, %{"sequence" => "000000000004"}]} =
               Log.read(store(), agent_id, starting_after: 2, limit: 2)

      assert {:ok, []} = Log.read(store(), agent_id, starting_after: 5)
      assert {:ok, []} = Log.read(store(), Wardrik.AgentID.parse!("test/nobody"))
      assert [:audit | logs] = Log.logs(store())
      assert agent_id in logs
    end
  end

  describe "trimming" do
    setup %{agent_id: agent_id, source: source} do
      old = fn payload -> %{Bus.Event.new(source, payload) | at: days_ago(31)} end
      writer = Writer.open(store(), Writer.new(agent_id), %{started(agent_id) | at: days_ago(31)})

      writer =
        Enum.reduce(
          [old.(%Bus.TurnStarted{messages: []}), old.(%Bus.TurnFinished{messages: []})],
          writer,
          fn event, w ->
            {:ok, w} = Writer.append(store(), w, event)
            w
          end
        )

      writer =
        writer
        |> append!(source, %Bus.TurnStarted{messages: []})
        |> append!(source, %Bus.TurnFinished{messages: []})

      %{writer: writer, cutoff: DateTime.add(DateTime.utc_now(), -30, :day)}
    end

    test "drops the events older than the cutoff, and tells a read from before them", %{
      agent_id: agent_id,
      cutoff: cutoff
    } do
      assert :ok = Log.trim(store(), agent_id, through: 5, before: cutoff)

      assert {:gap, 4} = Log.read(store(), agent_id)
      assert {:gap, 4} = Log.read(store(), agent_id, starting_after: 2)
      assert sequences(agent_id, 3) == [4, 5]
      assert Log.oldest(store(), agent_id) == 4

      assert :ok = Log.trim(store(), agent_id, through: 5, before: cutoff)
      assert Log.oldest(store(), agent_id) == 4
    end

    test "leaves the events to a trim that got there first", %{agent_id: agent_id, cutoff: cutoff} do
      expect(WardrikStore, :put, fn _store, _ns, _key, _dropped, _opts -> {:error, :conflict} end)

      assert {:error, :conflict} = Log.trim(store(), agent_id, through: 5, before: cutoff)
      assert sequences(agent_id) == [1, 2, 3, 4, 5]
    end

    test "drops none past the number it is given", %{agent_id: agent_id, cutoff: cutoff} do
      assert :ok = Log.trim(store(), agent_id, through: 2, before: cutoff)

      assert sequences(agent_id, 2) == [3, 4, 5]
    end

    test "never gives a number out twice, to an owner that starts from nothing", %{
      agent_id: agent_id,
      cutoff: cutoff
    } do
      :ok = Log.trim(store(), agent_id, through: 5, before: cutoff)

      open(agent_id)

      assert sequences(agent_id, 3) == [4, 5, 6]
    end
  end
end
