defmodule WardrikTUI.ViewTest do
  use ExUnit.Case, async: true

  import Wardrik.AgentID, only: [sigil_A: 2]

  alias Wardrik.Event
  alias Wardrik.Event.Source
  alias WardrikTUI.Activity
  alias WardrikTUI.Text
  alias WardrikTUI.View

  defp plain(data), do: Text.plain(data)

  defp sequences(%Owl.Tag{sequences: sequences, data: data}), do: sequences ++ sequences(data)
  defp sequences(list) when is_list(list), do: Enum.flat_map(list, &sequences/1)
  defp sequences(_other), do: []

  defp fold(activity, source, payload, now \\ 0) do
    Activity.fold(activity, Event.new(source, payload), now: now)
  end

  setup do
    turn = Source.root(~A"test/assistant", name: "turn")
    {:ok, turn: turn, tool: Source.child(turn, name: "web_search")}
  end

  describe "reasoning/1" do
    test "reasoning is marked and dimmed, so it cannot be read as the answer" do
      out = View.reasoning("pondering")

      assert plain(out) =~ "pondering"
      assert plain(out) =~ "┊"
      assert sequences(out) |> Enum.member?(:faint)
    end
  end

  describe "span/3" do
    setup %{turn: turn, tool: tool} do
      activity =
        Activity.new()
        |> fold(turn, {:turn_started, [Wardrik.Agent.Message.new("hi")]})
        |> fold(tool, {:span_started, "web_search"})

      {:ok, activity: activity}
    end

    test "a running span names itself and shows no time", %{activity: activity, tool: tool} do
      line = View.span(Activity.fetch(activity, tool.trace.span_id), 1, 5_000)

      assert plain(line) == "  · web_search\n"
    end

    test "indents by depth, so the tree is legible in scrollback", %{
      activity: activity,
      tool: tool
    } do
      span = Activity.fetch(activity, tool.trace.span_id)

      assert View.span(span, 0, 0) |> plain() == "· web_search\n"
      assert View.span(span, 2, 0) |> plain() == "    · web_search\n"
    end

    test "a finished span shows what it took", %{activity: activity, tool: tool} do
      activity = fold(activity, tool, {:span_finished, :ok, 1_250})
      line = View.span(Activity.fetch(activity, tool.trace.span_id), 1, 0)

      assert plain(line) == "  ✓ web_search · 1.3s\n"
      assert sequences(line) |> Enum.member?(:green)
    end

    test "a sub-second span is reported in milliseconds", %{activity: activity, tool: tool} do
      activity = fold(activity, tool, {:span_finished, :ok, 42})

      assert Activity.fetch(activity, tool.trace.span_id)
             |> View.span(1, 0)
             |> plain() =~ "42ms"
    end

    test "a failed span carries its reason", %{activity: activity, tool: tool} do
      activity = fold(activity, tool, {:span_finished, {:error, :timeout}, 20_000})
      line = View.span(Activity.fetch(activity, tool.trace.span_id), 1, 0)

      assert plain(line) == "  ✗ web_search · :timeout · 20.0s\n"
      assert sequences(line) |> Enum.member?(:red)
    end

    test "a span named after a paragraph is still one row", %{activity: activity, tool: tool} do
      long = String.duplicate("a long angle name ", 30)
      activity = fold(activity, tool, {:span_started, long})
      span = Activity.fetch(activity, tool.trace.span_id)

      for {depth, width} <- [{0, 80}, {1, 80}, {4, 80}, {1, 40}] do
        line = View.span(span, depth, 0, width) |> plain() |> String.trim_trailing("\n")

        refute line =~ "\n"
        assert String.length(line) < width
      end
    end

    test "a span nobody named still gets a line", %{turn: turn} do
      activity = Activity.new() |> fold(Source.child(turn), {:result, "hi"})
      [span] = Activity.spans(activity)

      assert View.span(span, 1, 0) |> plain() == "  · ?\n"
    end
  end

  describe "parked/1" do
    test "shows whoever answers here where to authorize a call" do
      call = %{
        id: "call_1",
        name: "github__issues",
        arguments: %{},
        link: %{url: "https://github.com/login/device", code: "WDJB-MJHT"}
      }

      shown =
        [{call, "To connect github, open its authorization link."}] |> View.parked() |> plain()

      assert shown =~ "To connect github"
      assert shown =~ "enter WDJB-MJHT at https://github.com/login/device"
    end
  end

  describe "trace/1" do
    test "approval traces distinguish waiting, rejection, and accepted decisions" do
      call = %{id: "deploy-1", name: "deploy", arguments: %{}}
      assert View.trace({:turn_parked, [{call, "Ship?"}]}) |> plain() =~ "waiting on deploy"

      assert View.trace({:turn_resumed, %{call.id => :approve}}) |> plain() =~
               "1 call(s) answered"

      assert View.trace({:tool_parked, call.id, call.name, "Ship?"}) |> plain() =~ "Ship?"
      denied = View.trace({:tool_denied, call.id, call.name, "Not today"})
      assert plain(denied) =~ "Not today"
      assert :red in sequences(denied)
    end

    test "names the model request and how it went" do
      assert View.trace({:model_started, "m0", :m}) |> plain() =~ "model"
      assert View.trace({:model_finished, "m0", :ok, 1_200, nil}) |> plain() =~ "ok 1.2s"

      failed = View.trace({:model_finished, "m0", {:error, :rate_limited}, 40, nil})

      assert plain(failed) =~ ":rate_limited"
      assert sequences(failed) |> Enum.member?(:red)
    end

    test "summarises tool calls by outcome" do
      assert View.trace({:tool_started, "c1", "echo", %{}, "key"}) |> plain() =~ "echo c1"
      assert View.trace({:tool_finished, "c1", "echo", {:ok, :x}}) |> plain() =~ "echo c1 ok"

      failed = View.trace({:tool_finished, "c1", "boom", {:error, :nope}})

      assert plain(failed) =~ ":nope"
      assert sequences(failed) |> Enum.member?(:red)
    end

    test "counts messages on a finished turn rather than dumping them" do
      assert View.trace({:turn_finished, [1, 2, 3]}) |> plain() =~ "3 message(s)"
    end

    test "ends each line so traces stack one per row" do
      assert View.trace({:meta, %{}}) |> plain() |> String.ends_with?("\n")
    end

    test "says nothing about events that have their own rendering" do
      assert View.trace({:result, "hi"}) == nil
      assert View.trace({:thinking, "hmm"}) == nil
      assert View.trace({:span_started, "echo"}) == nil
      assert View.trace({:span_finished, :ok, 1}) == nil
    end

    test "says nothing about an event shape it has never seen" do
      assert View.trace({:something_new, :whatever}) == nil
    end
  end

  describe "interrupted/1" do
    test "says how long it ran and what was dropped" do
      out =
        View.interrupted(%{dropped: 3, kept: 2, resolution: :stopped, elapsed_ms: 4_200})

      assert plain(out) =~ "stopped"
      assert plain(out) =~ "4.2s"
      assert plain(out) =~ "3 queued messages dropped"
    end

    test "a single dropped message is not pluralised" do
      out = View.interrupted(%{dropped: 1, kept: 0, resolution: :stopped, elapsed_ms: 10})

      assert plain(out) =~ "1 queued message dropped"
    end

    test "says nothing about a queue that was empty" do
      out = View.interrupted(%{dropped: 0, kept: 1, resolution: :stopped, elapsed_ms: 10})

      refute plain(out) =~ "dropped"
    end

    test "marks a turn that had to be killed" do
      out = View.interrupted(%{dropped: 0, kept: 0, resolution: :killed, elapsed_ms: 2_000})

      assert plain(out) =~ "killed"
    end

    test "an interrupt with nothing running says so" do
      out = View.interrupted(%{dropped: 0, kept: 0, resolution: :idle, elapsed_ms: 0})

      assert plain(out) =~ "nothing was running"
    end
  end

  test "error/1 stands out" do
    out = View.error(:rate_limited)

    assert plain(out) =~ ":rate_limited"
    assert sequences(out) |> Enum.member?(:red)
  end

  describe "tool results in the trace" do
    test "a successful call shows what it actually returned" do
      line =
        View.trace(
          {:tool_finished, "call_1", "list_services", {:ok, %{"services" => ["billing"]}}}
        )
        |> plain()

      assert line =~ "list_services"
      assert line =~ ~s({"services":["billing"]})
    end

    test "a string result is shown as it stands rather than re-encoded" do
      line =
        View.trace({:tool_finished, "call_1", "echo", {:ok, "plain text"}}) |> plain()

      assert line =~ "plain text"
    end

    test "a long result is truncated to keep a trace line a line" do
      output = %{"blob" => String.duplicate("x", 2_000)}
      line = View.trace({:tool_finished, "call_1", "dump", {:ok, output}}) |> plain()

      assert String.length(line) < 600
    end

    test "newlines are folded so one result stays one row" do
      line =
        View.trace({:tool_finished, "call_1", "read", {:ok, "one\ntwo\nthree"}})
        |> plain()

      refute line |> String.trim_trailing("\n") |> String.contains?("\n")
    end
  end
end
