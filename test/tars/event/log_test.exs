defmodule Tars.Event.LogTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Tars.Event
  alias Tars.Event.Log
  alias Tars.Event.Log.Entry
  alias Tars.Event.Log.Writer
  alias Tars.Event.Source
  alias Tars.Test.EventLog

  setup :verify_on_exit!

  setup do
    agent_id = "test/_/log-#{System.unique_integer([:positive])}"
    :ok = Log.subscribe(agent_id)

    %{agent_id: agent_id, source: Source.root(agent_id, name: "turn")}
  end

  defp started(agent_id),
    do: Event.new(Source.root(agent_id), {:agent_started, node(), :idle, "g1"})

  defp open(agent_id, head \\ 0), do: Writer.open(Writer.new(agent_id, head), started(agent_id))

  defp append!(writer, source, payload) do
    {:ok, writer} = Writer.append(writer, Event.new(source, payload))
    writer
  end

  defp sequences(agent_id, starting_after \\ 0) do
    {:ok, events} = Log.read(agent_id, starting_after: starting_after)
    Enum.map(events, &String.to_integer(&1["sequence"]))
  end

  defp days_ago(days),
    do: System.system_time(:microsecond) - days * 24 * 60 * 60 * 1_000_000

  describe "writing" do
    test "numbers each durable event from 1, writes it, then delivers it", %{
      agent_id: agent_id,
      source: source
    } do
      agent_id |> open() |> append!(source, {:turn_started, []})

      assert {:ok,
              [
                %{"type" => "tars.agent.started", "sequence" => "000000000001"},
                %{"type" => "tars.run.started", "sequence" => "000000000002"}
              ]} = Log.read(agent_id)

      assert_receive %Entry{sequence: 1, follows: 0, event: %{"type" => "tars.agent.started"}}
      assert_receive %Entry{sequence: 2, follows: 1, event: %{"type" => "tars.run.started"}}
    end

    test "delivers live events without writing them, a delta under the message its call opened",
         %{agent_id: agent_id, source: source} do
      agent_id
      |> open()
      |> append!(source, {:model_started, "s1.m0", "anthropic:claude-sonnet-5"})
      |> append!(source, {:chunk, "chunk"})
      |> append!(source, {:thinking, "hmm"})
      |> append!(source, {:result, "Hel"})
      |> append!(source, {:tool_progress, "call_1", "search", 1, 2})
      |> append!(source, {:model_finished, "s1.m0", :ok, 5, nil})
      |> append!(source, {:result, "lo"})

      assert EventLog.types(agent_id) == [
               "tars.agent.started",
               "tars.message.started",
               "tars.message.completed"
             ]

      assert_receive %Entry{sequence: 1}
      assert_receive %Entry{sequence: 2, event: %{"type" => "tars.message.started"}}

      assert_receive %Entry{
        sequence: nil,
        follows: 2,
        event: %{"type" => "tars.reasoning.delta", "data" => %{"message" => %{"id" => "s1.m0"}}}
      }

      assert_receive %Entry{
        sequence: nil,
        event: %{"type" => "tars.message.delta", "data" => %{"delta" => "Hel"}}
      }

      assert_receive %Entry{sequence: nil, event: %{"type" => "tars.tool_call.progress"}}
      assert_receive %Entry{sequence: 3, event: %{"type" => "tars.message.completed"}}
      refute_received %Entry{}
    end

    test "stops delivering to a subscriber that leaves", %{agent_id: agent_id, source: source} do
      writer = open(agent_id)
      assert_receive %Entry{sequence: 1}

      :ok = Log.unsubscribe(agent_id)
      append!(writer, source, {:turn_started, []})

      refute_received %Entry{}
    end

    test "an entry says whether it comes after the log read through a number" do
      live = %Entry{event: %{}, follows: 4}
      durable = %Entry{event: %{}, sequence: 4, follows: 3}

      assert Entry.follows?(live, 4)
      refute Entry.follows?(live, 5)
      assert Entry.follows?(durable, 3)
      refute Entry.follows?(durable, 4)
    end

    test "writes an event appended ahead of the bus once", %{agent_id: agent_id, source: source} do
      decided = Event.new(source, {:call_decided, "call_1", :approve, nil})

      {:ok, writer} = agent_id |> open() |> Writer.append_ahead(decided)
      {:ok, _writer} = Writer.append(writer, decided)

      assert EventLog.types(agent_id) == ["tars.agent.started", "tars.interrupt.resolved"]
    end
  end

  describe "owners" do
    test "an owner goes on from the last number written, whatever it was told", %{
      agent_id: agent_id,
      source: source
    } do
      Enum.reduce(1..20, open(agent_id), fn _n, writer ->
        append!(writer, source, {:turn_started, []})
      end)

      open(agent_id)
      open(agent_id, 7)

      assert sequences(agent_id) == Enum.to_list(1..23)
      assert Enum.count(EventLog.types(agent_id), &(&1 == "tars.agent.started")) == 3
    end

    test "the owner replaced stops writing", %{agent_id: agent_id, source: source} do
      first = open(agent_id)
      second = open(agent_id)

      assert {:error, :fenced, first} =
               Writer.append(first, Event.new(source, {:turn_started, []}))

      assert {:error, :fenced, _first} = Writer.append(first, Event.new(source, {:result, "x"}))
      append!(second, source, {:turn_resumed, %{}})

      assert EventLog.types(agent_id) == [
               "tars.agent.started",
               "tars.agent.started",
               "tars.run.resumed"
             ]
    end

    test "an owner that finds one before it still writing moves past it", %{agent_id: agent_id} do
      expect(Tars.Store, :put, fn ns, key, event, opts ->
        {:ok, _vsn} = call_original(Tars.Store, :put, [ns, key, %{event | "id" => "old"}, opts])
        {:error, :conflict}
      end)

      open(agent_id)

      assert {:ok, [%{"id" => "old"}, %{"type" => "tars.agent.started"}]} = Log.read(agent_id)
    end

    test "a write the store made without confirming it is taken as its own", %{
      agent_id: agent_id,
      source: source
    } do
      writer = open(agent_id)

      expect(Tars.Store, :put, fn ns, key, event, opts ->
        {:ok, _vsn} = call_original(Tars.Store, :put, [ns, key, event, opts])
        {:error, :unavailable}
      end)

      assert {:error, :unavailable, writer} =
               Writer.append(writer, Event.new(source, {:turn_started, []}))

      append!(writer, source, {:turn_resumed, %{}})

      assert EventLog.types(agent_id) == [
               "tars.agent.started",
               "tars.run.started",
               "tars.run.resumed"
             ]
    end

    test "an owner that could not write its start writes it when it comes from the bus", %{
      agent_id: agent_id
    } do
      started = started(agent_id)
      expect(Tars.Store, :put, fn _ns, _key, _event, _opts -> {:error, :unavailable} end)

      writer = Writer.open(Writer.new(agent_id), started)
      assert {:ok, []} = Log.read(agent_id)

      assert {:ok, _writer} = Writer.append(writer, started)
      assert EventLog.types(agent_id) == ["tars.agent.started"]
    end

    test "a write the store failed leaves its number to the next", %{
      agent_id: agent_id,
      source: source
    } do
      writer = open(agent_id)
      expect(Tars.Store, :put, fn _ns, _key, _event, _opts -> {:error, :unavailable} end)

      assert {:error, :unavailable, writer} =
               Writer.append(writer, Event.new(source, {:turn_started, []}))

      append!(writer, source, {:turn_resumed, %{}})

      assert EventLog.types(agent_id) == ["tars.agent.started", "tars.run.resumed"]
      assert sequences(agent_id) == [1, 2]
    end
  end

  describe "reading" do
    test "answers the events after a number, as many as asked", %{
      agent_id: agent_id,
      source: source
    } do
      Enum.reduce(1..4, open(agent_id), fn _n, writer ->
        append!(writer, source, {:turn_started, []})
      end)

      assert {:ok, [%{"sequence" => "000000000003"}, %{"sequence" => "000000000004"}]} =
               Log.read(agent_id, starting_after: 2, limit: 2)

      assert {:ok, []} = Log.read(agent_id, starting_after: 5)
      assert {:ok, []} = Log.read("test/_/nobody")
    end
  end

  describe "trimming" do
    setup %{agent_id: agent_id, source: source} do
      old = fn payload -> %{Event.new(source, payload) | at: days_ago(31)} end
      writer = Writer.open(Writer.new(agent_id), %{started(agent_id) | at: days_ago(31)})

      writer =
        Enum.reduce([old.({:turn_started, []}), old.({:turn_finished, []})], writer, fn event,
                                                                                        w ->
          {:ok, w} = Writer.append(w, event)
          w
        end)

      writer =
        writer |> append!(source, {:turn_started, []}) |> append!(source, {:turn_finished, []})

      %{writer: writer, cutoff: DateTime.add(DateTime.utc_now(), -30, :day)}
    end

    test "drops the events older than the cutoff, and tells a read from before them", %{
      agent_id: agent_id,
      cutoff: cutoff
    } do
      assert :ok = Log.trim(agent_id, 5, cutoff)

      assert {:gap, 4} = Log.read(agent_id)
      assert {:gap, 4} = Log.read(agent_id, starting_after: 2)
      assert sequences(agent_id, 3) == [4, 5]
      assert Log.oldest(agent_id) == 4

      assert :ok = Log.trim(agent_id, 5, cutoff)
      assert Log.oldest(agent_id) == 4
    end

    test "leaves the events to a trim that got there first", %{agent_id: agent_id, cutoff: cutoff} do
      expect(Tars.Store, :put, fn _ns, _key, _dropped, _opts -> {:error, :conflict} end)

      assert {:error, :conflict} = Log.trim(agent_id, 5, cutoff)
      assert sequences(agent_id) == [1, 2, 3, 4, 5]
    end

    test "drops none past the number it is given", %{agent_id: agent_id, cutoff: cutoff} do
      assert :ok = Log.trim(agent_id, 2, cutoff)

      assert sequences(agent_id, 2) == [3, 4, 5]
    end

    test "never gives a number out twice, to an owner that starts from nothing", %{
      agent_id: agent_id,
      cutoff: cutoff
    } do
      :ok = Log.trim(agent_id, 5, cutoff)

      open(agent_id)

      assert sequences(agent_id, 3) == [4, 5, 6]
    end
  end
end
