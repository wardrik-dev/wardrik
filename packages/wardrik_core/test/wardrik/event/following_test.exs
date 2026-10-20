defmodule Wardrik.Event.FollowingTest do
  use ExUnit.Case, async: true

  import Wardrik.Test, only: [store: 0]

  alias Wardrik.AgentID
  alias Wardrik.Event
  alias Wardrik.Event.Log
  alias Wardrik.Event.Log.Entry
  alias Wardrik.Event.Log.Writer
  alias Wardrik.Event.Source
  alias Wardrik.Resource

  # Agents of their own for each test, `<prefix>-a` and `<prefix>-b`, which
  # the pattern `test/agent/<prefix>-*` covers.
  setup do
    prefix = "following#{System.unique_integer([:positive])}"
    agent = &AgentID.new!("#{prefix}-#{&1}", org: "test")

    %{
      a: agent.("a"),
      b: agent.("b"),
      pattern: Resource.parse!("test/agent/#{prefix}-*")
    }
  end

  defp entry(log, type, follows, sequence \\ nil),
    do: %Entry{log: log, event: %{"type" => type}, follows: follows, sequence: sequence}

  # `count` runs started in `agent_id`'s log, after `agent.started`, the
  # first `old` of them, and the start before them, long ago.
  defp written(agent_id, count, old \\ 0) do
    long_ago = System.system_time(:microsecond) - 31 * 24 * 60 * 60 * 1_000_000
    at = fn n -> if n <= old, do: long_ago, else: System.system_time(:microsecond) end

    started =
      Event.new(Source.root(agent_id), %Event.AgentStarted{
        node: node(),
        status: :idle,
        generation: "g1"
      })

    writer = Writer.open(store(), Writer.new(agent_id), %{started | at: at.(old)})

    Enum.reduce(1..count//1, writer, fn n, writer ->
      event = Event.new(Source.root(agent_id), %Event.TurnStarted{messages: []})
      {:ok, writer} = Writer.append(store(), writer, %{event | at: at.(n)})
      writer
    end)
  end

  defp stream(resources, opts),
    do: Log.stream(store(), resources, Keyword.merge([follow: false, types: :all], opts))

  defp read(entries), do: Enum.map(entries, &{&1.log, &1.sequence, &1.event["type"]})

  describe "subscribing" do
    test "takes the entries of each agent a pattern covers, of the types it names", ctx do
      :ok = Log.subscribe([ctx.pattern], ["wardrik.run.started"])

      :ok = Log.publish(entry(ctx.a, "wardrik.run.started", 0, 1))
      :ok = Log.publish(entry(ctx.a, "wardrik.message.delta", 1))
      :ok = Log.publish(entry(AgentID.new!("other", org: "test"), "wardrik.run.started", 0, 1))

      a = ctx.a
      assert_received %Entry{log: ^a, sequence: 1}
      refute_received %Entry{}
    end

    test "matches a pattern with a wildcard where its org is", ctx do
      :ok = Log.subscribe([Resource.parse!("*/agent/#{ctx.a.name}")], :all)

      :ok = Log.publish(entry(ctx.a, "wardrik.run.started", 0, 1))
      :ok = Log.publish(entry(ctx.b, "wardrik.run.started", 0, 1))

      a = ctx.a
      assert_received %Entry{log: ^a}
      refute_received %Entry{}
    end

    test "sends a process each entry once, however many of its patterns cover it", ctx do
      :ok = Log.subscribe([ctx.pattern, Resource.parse!("*/agent/#{ctx.a.name}")], :all)
      :ok = Log.subscribe(ctx.a)

      :ok = Log.publish(entry(ctx.a, "wardrik.run.started", 0, 1))

      assert_received %Entry{}
      refute_received %Entry{}
    end

    test "adds to what a process follows, and takes away one pattern alone", ctx do
      :ok = Log.subscribe([ctx.pattern], ["wardrik.run.started"])
      :ok = Log.subscribe([ctx.pattern], ["wardrik.run.completed"])
      :ok = Log.subscribe(ctx.b)

      :ok = Log.publish(entry(ctx.a, "wardrik.run.completed", 1, 2))
      assert_received %Entry{sequence: 2}

      :ok = Log.unsubscribe([ctx.pattern])
      :ok = Log.publish(entry(ctx.a, "wardrik.run.started", 2, 3))
      :ok = Log.publish(entry(ctx.b, "wardrik.run.started", 0, 1))

      b = ctx.b
      assert_received %Entry{log: ^b}
      refute_received %Entry{}

      :ok = Log.unsubscribe(ctx.b)
      :ok = Log.publish(entry(ctx.b, "wardrik.run.started", 1, 2))
      refute_received %Entry{}
    end
  end

  describe "reading" do
    test "reads each log a pattern covers after its position, a log at a time", ctx do
      written(ctx.a, 2)
      written(ctx.b, 1)

      assert [{a, 2, _}, {a, 3, "wardrik.run.started"}, {b, 1, _}, {b, 2, _}] =
               [ctx.pattern] |> stream(after: %{ctx.a => 1}) |> read()

      assert {a, b} == {ctx.a, ctx.b}
    end

    test "takes the types it names alone", ctx do
      written(ctx.a, 2)

      assert [{_a, 2, "wardrik.run.started"}, {_, 3, "wardrik.run.started"}] =
               [ctx.pattern]
               |> stream(after: %{}, types: ["wardrik.run.started"])
               |> read()
    end

    test "says where a log was trimmed past it, whatever types it takes, and reads on", ctx do
      written(ctx.a, 4, 2)
      cutoff = DateTime.add(DateTime.utc_now(), -30, :day)
      :ok = Log.trim(store(), ctx.a, through: 5, before: cutoff)

      assert [{_a, nil, "wardrik.events.dropped"}, {_, 4, _}, {_, 5, _}] =
               [ctx.pattern]
               |> stream(after: %{}, types: ["wardrik.run.started"])
               |> read()
    end

    test "says where a log was trimmed past it, and reads on from the oldest it holds", ctx do
      written(ctx.a, 4, 2)
      cutoff = DateTime.add(DateTime.utc_now(), -30, :day)
      :ok = Log.trim(store(), ctx.a, through: 5, before: cutoff)

      assert [%Entry{sequence: nil, follows: 3} = dropped | rest] =
               Enum.to_list(stream([ctx.pattern], after: %{ctx.a => 1}))

      assert %{"type" => "wardrik.events.dropped", "data" => %{"after" => 1, "oldest" => 4}} =
               dropped.event

      assert Enum.map(rest, & &1.sequence) == [4, 5]
    end

    test "from the head, reads nothing", ctx do
      written(ctx.a, 1)

      assert [] = Enum.to_list(stream([ctx.pattern], after: :head))
    end

    test "the heads are the last sequence of each log a pattern covers, past what was dropped",
         ctx do
      written(ctx.a, 4, 2)
      written(ctx.b, 0)
      cutoff = DateTime.add(DateTime.utc_now(), -30, :day)
      :ok = Log.trim(store(), ctx.a, through: 5, before: cutoff)

      assert Log.heads(store(), [ctx.pattern]) == %{ctx.a => 5, ctx.b => 1}
      assert [] = Enum.to_list(stream([ctx.pattern], after: Log.heads(store(), [ctx.pattern])))
    end
  end

  describe "following" do
    test "takes each entry written after what it read, once, in order", ctx do
      written(ctx.a, 0)
      test = self()

      task =
        Task.async(fn ->
          [ctx.pattern]
          |> stream(after: %{}, follow: true)
          |> Stream.each(&send(test, {:took, &1.sequence}))
          |> Enum.take(4)
        end)

      assert_receive {:took, 1}
      :ok = Log.publish(entry(ctx.a, "wardrik.run.started", 0, 1))
      :ok = Log.publish(entry(ctx.a, "wardrik.run.started", 1, 2))
      :ok = Log.publish(entry(ctx.a, "wardrik.message.delta", 2))
      written(ctx.b, 0)

      assert [{a, 1, _}, {a, 2, _}, {a, nil, _}, {b, 1, _}] = read(Task.await(task))
      assert {a, b} == {ctx.a, ctx.b}
    end

    test "from the head, takes each agent's from its first entry", ctx do
      written(ctx.a, 2)
      :ok = Group.monitor(Log, "test")

      task =
        Task.async(fn ->
          [AgentID.resource(ctx.a)] |> stream(after: :head, follow: true) |> Enum.take(3)
        end)

      await_subscribed(task.pid)
      :ok = Log.publish(entry(ctx.a, "wardrik.message.delta", 3))
      :ok = Log.publish(entry(ctx.a, "wardrik.message.delta", 2))
      :ok = Log.publish(entry(ctx.a, "wardrik.run.started", 3, 4))
      :ok = Log.publish(entry(ctx.a, "wardrik.run.started", 4, 5))

      assert [nil, 4, 5] = task |> Task.await() |> Enum.map(& &1.sequence)
    end

    test "reads the events an entry follows that it has not read before it", ctx do
      for sequence <- 1..2 do
        event = %{"type" => "wardrik.run.started", "sequence" => "#{sequence}"}
        key = Log.key(ctx.a, sequence)
        {:ok, _vsn} = WardrikStore.put(store(), Log.namespace(), key, event, if_vsn: nil)
      end

      :ok = Group.monitor(Log, "test")

      task =
        Task.async(fn -> [ctx.pattern] |> stream(after: %{}, follow: true) |> Enum.take(3) end)

      await_subscribed(task.pid)
      :ok = Log.publish(entry(ctx.a, "wardrik.message.delta", 2))

      assert [1, 2, nil] = task |> Task.await() |> Enum.map(& &1.sequence)
    end

    test "leaves what it followed once it stops, and what was sent it", ctx do
      test = self()

      spawn_link(fn ->
        :ok = Group.monitor(Log, "test")
        send(test, :monitoring)
        await_subscribed(test)
        Log.publish(entry(ctx.a, "wardrik.run.started", 0, 1))
      end)

      assert_receive :monitoring

      assert [%Entry{sequence: 1}] =
               [ctx.pattern]
               |> stream(after: :head, follow: true)
               |> Stream.each(&send(test, %{&1 | sequence: 2}))
               |> Enum.take(1)

      :ok = Log.publish(entry(ctx.a, "wardrik.run.started", 2, 3))
      refute_received %Entry{}
    end
  end

  # Waits for `pid` to subscribe to an agent of the org test, whose topic
  # the caller monitors.
  defp await_subscribed(pid) do
    receive do
      {:group, events, _info} ->
        unless Enum.any?(events, &(&1.type == :joined and &1.pid == pid)),
          do: await_subscribed(pid)
    after
      2_000 -> flunk("#{inspect(pid)} never subscribed")
    end
  end
end
